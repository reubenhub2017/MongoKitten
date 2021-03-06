import Foundation
import NIO

// TODO: https://github.com/mongodb/specifications/tree/master/source/server-selection
// TODO: https://github.com/mongodb/specifications/tree/master/source/server-discovery-and-monitoring
// TODO: https://github.com/mongodb/specifications/tree/master/source/max-staleness
// TODO: https://github.com/mongodb/specifications/tree/master/source/initial-dns-seedlist-discovery

public final class Cluster {
    let eventLoop: EventLoop
    let settings: ConnectionSettings
    let sessionManager: SessionManager
    
    /// The shared ObjectId generator for this cluster
    /// Using the shared generator is more efficient and correct than `ObjectId()`
    internal let sharedGenerator = ObjectIdGenerator()
    
    public var heartbeatFrequency = TimeAmount.seconds(10) {
        didSet {
            if heartbeatFrequency < .milliseconds(500) {
                heartbeatFrequency = .milliseconds(500)
            }
        }
    }
    
    public var slaveOk = false {
        didSet {
            for connection in pool {
                connection.connection.slaveOk = self.slaveOk
            }
        }
    }
    
    private var pool: [PooledConnection]
    
    /// Returns the database named `database`, on this connection
    public subscript(database: String) -> Database {
        return Database(
            named: database,
            session: sessionManager.makeImplicitSession(for: self)
        )
    }
    
    private init(eventLoop: EventLoop, sessionManager: SessionManager, settings: ConnectionSettings) {
        self.eventLoop = eventLoop
        self.sessionManager = sessionManager
        self.settings = settings
        self.pool = []
        self.hosts = Set(settings.hosts)
    }
    
    private func send(context: MongoDBCommandContext) -> EventLoopFuture<ServerReply> {
        let future = self.getConnection().thenIfError { _ in
            return self.getConnection(writable: true)
            }.then { connection -> EventLoopFuture<Void> in
                connection.context.queries.append(context)
                return connection.channel.writeAndFlush(context)
        }
        future.cascadeFailure(promise: context.promise)
        
        return future.then { context.promise.futureResult }
    }
    
    func send<C: MongoDBCommand>(command: C, session: ClientSession? = nil) -> EventLoopFuture<ServerReply> {
        let context = MongoDBCommandContext(
            command: command,
            requestID: 0,
            retry: true,
            session: session,
            promise: self.eventLoop.newPromise()
        )
        
        return send(context: context)
    }
    
    public static func connect(on group: EventLoopGroup, settings: ConnectionSettings) -> EventLoopFuture<Cluster> {
        let loop = group.next()
        
        guard settings.hosts.count > 0 else {
            return loop.newFailedFuture(error: MongoKittenError(.unableToConnect, reason: .noHostSpecified))
        }
        
        let sessionManager = SessionManager()
        let cluster = Cluster(eventLoop: loop, sessionManager: sessionManager, settings: settings)
        let connected = cluster.getConnection().then { _ in
            return cluster.rediscover().map { return cluster }
        }
            
        connected.whenSuccess { cluster in
            cluster.scheduleDiscovery()
        }
        
        return connected
    }
    
    private func scheduleDiscovery() {
        _ = eventLoop.scheduleTask(in: heartbeatFrequency) { [weak self] in
            guard let `self` = self else { return }
            
            self.rediscover().whenSuccess(self.scheduleDiscovery)
        }
    }
    
    private var hosts: Set<ConnectionSettings.Host>
    private var discoveredHosts = Set<ConnectionSettings.Host>()
    private var undiscoveredHosts: Set<ConnectionSettings.Host> {
        return hosts.subtracting(discoveredHosts).subtracting(timeoutHosts)
    }
    private var timeoutHosts = Set<ConnectionSettings.Host>()
    
    private func updateSDAM(from handshake: ConnectionHandshakeReply) {
        var hosts = handshake.hosts ?? []
        hosts += handshake.passives ?? []
        
        for host in hosts {
            do {
                let host = try ConnectionSettings.Host(host)
                self.hosts.insert(host)
            } catch { }
        }
    }
    
    private func makeConnection(to host: ConnectionSettings.Host) -> EventLoopFuture<PooledConnection> {
        discoveredHosts.insert(host)
        
        // TODO: Failed to connect, different host until all hosts have been had
        let connection = Connection.connect(
            for: self,
            host: host
            ).map { connection -> PooledConnection in
                connection.slaveOk = self.slaveOk
                
                /// Ensures we default to the cluster's lowest version
                if let connectionHandshake = connection.handshakeResult {
                    self.updateSDAM(from: connectionHandshake)
                }
                
                let connectionId = ObjectIdentifier(connection)
                connection.channel.closeFuture.whenComplete { [weak self] in
                    guard let me = self else { return }
                    
                    me.remove(connectionId: connectionId)
                }
                
                return PooledConnection(host: host, connection: connection)
        }
        
        connection.whenFailure { error in
            self.timeoutHosts.insert(host)
            self.discoveredHosts.remove(host)
        }
        
        return connection
    }
    
    /// Checks all known hosts for isMaster and writability
    private func rediscover() -> EventLoopFuture<Void> {
        var handshakes = [EventLoopFuture<Void>]()
        
        for pooledConnection in pool {
            let handshake = pooledConnection.connection.executeHandshake(withClientMetadata: false)
            handshake.whenSuccess {
                if let handshake = pooledConnection.connection.handshakeResult {
                    self.updateSDAM(from: handshake)
                }
            }
            handshake.whenFailure { _ in
                self.discoveredHosts.remove(pooledConnection.host)
            }
            
            handshakes.append(handshake)
        }
        
        self.timeoutHosts = []
        return EventLoopFuture<Void>.andAll(handshakes, eventLoop: self.eventLoop)
    }
    
    private func remove(connectionId: ObjectIdentifier) {
        if let index = self.pool.firstIndex(where: { ObjectIdentifier($0.connection) == connectionId }) {
            let pooledConnection = self.pool[index]
            self.pool.remove(at: index)
            self.discoveredHosts.remove(pooledConnection.host)
            pooledConnection.connection.context.prepareForResend()
            
            let rediscovery = self.rediscover()
            let queries = pooledConnection.connection.context.queries
            
            rediscovery.whenSuccess {
                for query in queries {
                    // Retry the query
                    _ = self.send(context: query)
                }
            }
            
            rediscovery.whenFailure { error in
                for query in queries {
                    // Retry the query
                    query.promise.fail(error: error)
                }
            }
            
            // So they don't get failed on deinit of the connection
            pooledConnection.connection.context.queries = []
        }
    }
    
    func findMatchingConnection(writable: Bool) -> PooledConnection? {
        var matchingConnection: PooledConnection?
        
        nextConnection: for pooledConnection in pool {
            let connection = pooledConnection.connection
            
            guard !connection.context.isClosed, let handshakeResult = connection.handshakeResult else {
                self.remove(connectionId: ObjectIdentifier(connection))
                continue nextConnection
            }
            
            let unwritable = writable && handshakeResult.readOnly ?? false
            let unreadable = !self.slaveOk && !handshakeResult.ismaster
            
            if unwritable || unreadable {
                continue nextConnection
            }
            
            matchingConnection = pooledConnection
        }
        
        return matchingConnection
    }
    
    func getConnection(writable: Bool = true) -> EventLoopFuture<Connection> {
        if let matchingConnection = findMatchingConnection(writable: writable) {
            return eventLoop.newSucceededFuture(result: matchingConnection.connection)
        }
        
        guard let host = undiscoveredHosts.first else {
            return self.rediscover().thenThrowing { _ in
                guard let match = self.findMatchingConnection(writable: writable) else {
                    throw MongoKittenError(.unableToConnect, reason: .noAvailableHosts)
                }
                
                return match.connection
            }
        }
        
        return makeConnection(to: host).then { pooledConnection in
            self.pool.append(pooledConnection)
            
            guard let handshake = pooledConnection.connection.handshakeResult else {
                return self.eventLoop.newFailedFuture(error: MongoKittenError(.unableToConnect, reason: .handshakeFailed))
            }
            
            let unwritable = writable && handshake.readOnly == true
            let unreadable = !self.slaveOk && !handshake.ismaster
            
            if unwritable || unreadable {
                return self.getConnection(writable: writable)
            } else {
                return self.eventLoop.newSucceededFuture(result: pooledConnection.connection)
            }
        }
    }
}

struct PooledConnection {
    let host: ConnectionSettings.Host
    let connection: Connection
}
