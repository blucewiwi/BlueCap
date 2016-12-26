//
//  PeripheralsViewController.swift
//  BlueCapUI
//
//  Created by Troy Stribling on 6/5/14.
//  Copyright (c) 2014 Troy Stribling. The MIT License (MIT).
//

import UIKit
import CoreBluetooth
import BlueCapKit

class SerialUUIDQueue {
    let queue = Queue("serial-uuid-queue")
    var uuids = [UUID]()

    var isEmpty: Bool {
        return queue.sync { self.uuids.count == 0 }
    }

    func push(_ uuid: UUID) {
        queue.sync {
            guard !self.uuids.contains(uuid) else {
                return
            }
            self.uuids.append(uuid)
        }
    }

    func shift() -> UUID? {
        return queue.sync {
            guard self.uuids.count > 0 else {
                return nil
            }
            return self.uuids.remove(at: 0)
        }
    }

    func removeAll() {
        queue.sync { self.uuids.removeAll() }
    }

    func set(_ peripherals: [Peripheral]) {
        queue.sync { peripherals.forEach { peripheral in
            guard !self.uuids.contains(peripheral.identifier) else {
                return
            }
            self.uuids.append(peripheral.identifier)
        } }
    }
}

class PeripheralsViewController : UITableViewController {

    var stopScanBarButtonItem: UIBarButtonItem!
    var startScanBarButtonItem: UIBarButtonItem!

    var isScanning = false
    var shouldUpdateConnections = false
    var discoveryLimitReached = false

    var peripheralsToConnect = SerialUUIDQueue()
    var peripheralsToDisconnect = SerialUUIDQueue()

    var connectingPeripherals = Set<UUID>()
    var connectedPeripherals = Set<UUID>()
    var discoveredPeripherals = Set<UUID>()
    var removedPeripherals = Set<UUID>()
    var peripheralAdvertisments = [UUID : PeripheralAdvertisements]()

    var didReset = false

    var atDiscoveryLimit: Bool {
        return Singletons.discoveryManager.peripherals.count >= ConfigStore.getMaximumPeripheralsDiscovered()
    }

    var allPeripheralsConnected: Bool {
        return connectedPeripherals.count == Singletons.discoveryManager.peripherals.count
    }

    var peripheralsSortedByRSSI: [Peripheral] {
        return Singletons.discoveryManager.peripherals.sorted() { (p1, p2) -> Bool in
            guard let p1RSSI = Singletons.scanningManager.discoveredPeripherals[p1.identifier],
                  let p2RSSI = Singletons.scanningManager.discoveredPeripherals[p2.identifier] else {
                    return false
            }
            if (p1RSSI.RSSI == 127 || p1RSSI.RSSI == 0) && (p2RSSI.RSSI != 127  || p2RSSI.RSSI != 0) {
                return false
            }  else if (p1RSSI.RSSI != 127 || p1RSSI.RSSI != 0) && (p2RSSI.RSSI == 127 || p2RSSI.RSSI == 0) {
                return true
            } else if (p1RSSI.RSSI == 127 || p1RSSI.RSSI == 0) && (p2RSSI.RSSI == 127 || p2RSSI.RSSI == 0) {
                return true
            } else {
                return p1RSSI.RSSI >= p2RSSI.RSSI
            }
        }
    }

    var peripherals: [Peripheral] {
        if ConfigStore.getPeripheralSortOrder() == .discoveryDate {
            return Singletons.discoveryManager.peripherals
        } else {
            return self.peripheralsSortedByRSSI
        }
    }

    struct MainStoryboard {
        static let peripheralCell = "PeripheralCell"
        static let peripheralSegue = "Peripheral"
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        navigationItem.backBarButtonItem = UIBarButtonItem(title: "", style: .plain, target: nil, action: nil)
        stopScanBarButtonItem = UIBarButtonItem(barButtonSystemItem: .stop, target: self, action: #selector(PeripheralsViewController.toggleScan(_:)))
        startScanBarButtonItem = UIBarButtonItem(title: "Scan", style: UIBarButtonItemStyle.plain, target: self, action: #selector(PeripheralsViewController.toggleScan(_:)))
        styleUIBarButton(self.startScanBarButtonItem)
        Singletons.discoveryManager.whenStateChanges().onSuccess { state in
            Logger.debug("discoveryManager state changed: \(state)")
        }
        Singletons.scanningManager.whenStateChanges().onSuccess { [weak self] state in
            self.forEach { strongSelf in
                Logger.debug("scanningManager state changed: \(state)")
                switch state {
                case .poweredOn:
                    if strongSelf.didReset {
                        strongSelf.didReset = false
                        strongSelf.startScan()
                        strongSelf.updatePeripheralConnectionsIfNecessary()
                    }
                case .unknown:
                    break
                case .poweredOff, .unauthorized:
                    strongSelf.alertAndStopScanning(message: "DiscoveryManager state \"\(state)\"")
                case .resetting:
                    strongSelf.stopScan()
                    strongSelf.setScanButton()
                    strongSelf.didReset = true
                    sleep(1)
                    Singletons.scanningManager.reset()
                case .unsupported:
                    strongSelf.alertAndStopScanning(message: "DiscoveryManager state \"\(state)\". Bluetooth not supported.")
                }
            }
        }
        Singletons.discoveryManager.whenStateChanges().onSuccess { [weak self] state in
            self.forEach { strongSelf in
                Logger.debug("scanningManager state changed: \(state)")
                switch state {
                case .resetting:
                    Singletons.discoveryManager.reset()
                default:
                    break
                }
            }
        }
    }

    func alertAndStopScanning(message: String) {
        present(UIAlertController.alert(message: message), animated:true) { [weak self] _ in
            self.forEach { strongSelf in
                strongSelf.stopScan()
                strongSelf.setScanButton()
                Singletons.discoveryManager.reset()
                Singletons.scanningManager.reset()
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.styleNavigationBar()
        self.setScanButton()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        shouldUpdateConnections = true
        restartConnectionUpdatesIfNecessary()
        updatePeripheralConnectionsIfNecessary()
        NotificationCenter.default.addObserver(self, selector:#selector(PeripheralsViewController.didBecomeActive), name: NSNotification.Name.UIApplicationDidBecomeActive, object:nil)
        NotificationCenter.default.addObserver(self, selector:#selector(PeripheralsViewController.didEnterBackground), name: NSNotification.Name.UIApplicationDidEnterBackground, object:nil)
        setScanButton()
        updateWhenActive()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NotificationCenter.default.removeObserver(self)
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any!) {
        if segue.identifier == MainStoryboard.peripheralSegue {
            if let selectedIndex = self.tableView.indexPath(for: sender as! UITableViewCell) {
                let viewController = segue.destination as! PeripheralViewController
                let peripheral = self.peripherals[selectedIndex.row]
                viewController.peripheral = peripheral
                viewController.peripheralDiscovered = discoveredPeripherals.contains(peripheral.identifier)
                viewController.peripheralAdvertisements = peripheralAdvertisments[peripheral.identifier]
            }
        }
    }

    func toggleScan(_ sender: AnyObject) {
        guard !Singletons.beaconManager.isMonitoring else {
            present(UIAlertController.alert(message: "iBeacon monitoring is active. Cannot scan and monitor iBeacons simutaneously. Stop iBeacon monitoring to start scan"), animated:true, completion:nil)
            return
        }
        guard Singletons.discoveryManager.poweredOn else {
            present(UIAlertController.alert(message: "Bluetooth is not enabled. Enable Bluetooth in settings."), animated:true, completion:nil)
            return
        }
        guard Singletons.scanningManager.poweredOn else {
            present(UIAlertController.alert(message: "Bluetooth is not enabled. Enable Bluetooth in settings."), animated:true, completion:nil)
            return
        }
        if self.isScanning {
            Logger.debug("Scan toggled off")
            stopScan()
        } else {
            Logger.debug("Scan toggled on")
            startScan()
            updatePeripheralConnectionsIfNecessary()
        }
        setScanButton()
    }

    func didBecomeActive() {
        Logger.debug()
        tableView.reloadData()
        setScanButton()
    }

    func didEnterBackground() {
        Logger.debug()
        stopScan()
    }

    func setScanButton() {
        if isScanning {
            navigationItem.setLeftBarButton(self.stopScanBarButtonItem, animated:false)
        } else {
            navigationItem.setLeftBarButton(self.startScanBarButtonItem, animated:false)
        }
    }

    // MARK: Peripheral Connection

    func disconnectConnectingPeripherals() {
        for peripheral in peripherals where connectingPeripherals.contains(peripheral.identifier) {
            peripheral.disconnect()
        }
    }

    func connectPeripheralsIfNecessary() {
        guard shouldUpdateConnections else {
            Logger.debug("connection updates disabled")
            disconnectConnectingPeripherals()
            return
        }
        let maxConnections = ConfigStore.getMaximumPeripheralsConnected()
        var connectingCount = connectingPeripherals.count
        guard connectingCount < maxConnections else {
            Logger.debug("max connections reached")
            return
        }
        while let peripheralIdentifier = peripheralsToConnect.shift() {
            guard let peripheral = Singletons.discoveryManager.discoveredPeripherals[peripheralIdentifier] else {
                Logger.debug("peripheral with identifier '\(peripheralIdentifier.uuidString)' not found")
                continue
            }
            Logger.debug("Connecting peripheral: '\(peripheral.name)', \(peripheral.identifier.uuidString)")
            connectingPeripherals.insert(peripheral.identifier)
            connect(peripheral)
            connectingCount += 1
            guard connectingCount < maxConnections else {
                Logger.debug("max connections reached")
                return
            }
        }
    }

    func disconnectConnectedPeripheralsIfNecessary() {
        guard shouldUpdateConnections else {
            Logger.debug("connection updates disabled")
            return
        }
        let maxConnections = ConfigStore.getMaximumPeripheralsConnected()
        guard maxConnections < peripherals.count else {
            return
        }
        while let peripheralIdentifier = peripheralsToDisconnect.shift() {
            guard let peripheral = Singletons.discoveryManager.discoveredPeripherals[peripheralIdentifier] else {
                Logger.debug("peripheral with identifier '\(peripheralIdentifier.uuidString)' not found")
                continue
            }
            Logger.debug("Disconnecting peripheral: '\(peripheral.name)', \(peripheral.identifier.uuidString)")
            peripheral.disconnect()
        }
    }

    func updatePeripheralConnectionsIfNecessary() {
        guard shouldUpdateConnections else {
            Logger.debug("connection updates disabled")
            return
        }
        Queue.main.delay(Params.updateConnectionsInterval) { [weak self] in
            self.forEach { strongSelf in
                strongSelf.disconnectConnectedPeripheralsIfNecessary()
                strongSelf.connectPeripheralsIfNecessary()
                strongSelf.updateWhenActive()
                strongSelf.updatePeripheralConnectionsIfNecessary()
            }
        }
    }

    func connect(_ peripheral: Peripheral) {
        Logger.debug("Connect peripheral: '\(peripheral.name)'', \(peripheral.identifier.uuidString)")
        let maxTimeouts = ConfigStore.getPeripheralMaximumTimeoutsEnabled() ? ConfigStore.getPeripheralMaximumTimeouts() : UInt.max
        let maxDisconnections = ConfigStore.getPeripheralMaximumDisconnectionsEnabled() ? ConfigStore.getPeripheralMaximumDisconnections() : UInt.max
        let connectionTimeout = ConfigStore.getPeripheralConnectionTimeoutEnabled() ? Double(ConfigStore.getPeripheralConnectionTimeout()) : Double.infinity
        let connectionFuture = peripheral.connect(timeoutRetries: maxTimeouts, disconnectRetries: maxDisconnections, connectionTimeout: connectionTimeout, capacity: 10)

        connectionFuture.onSuccess { [weak self] _ in
            self.forEach { strongSelf in
                Logger.debug("Connected peripheral: '\(peripheral.name)', \(peripheral.identifier.uuidString)")
                strongSelf.connectedPeripherals.insert(peripheral.identifier)
                strongSelf.discoverPeripheral(peripheral)
                strongSelf.updateWhenActive()
            }
        }

        connectionFuture.onFailure { [weak self] error in
            Logger.debug("Connection failed: '\(peripheral.name)', \(peripheral.identifier.uuidString)")
            self.forEach { strongSelf in
                strongSelf.connectingPeripherals.remove(peripheral.identifier)
                guard let peripheralError = error as? PeripheralError, peripheralError != .forcedDisconnect else {
                    Logger.debug("Forced Disconnection: '\(peripheral.name)', \(peripheral.identifier.uuidString)")
                    strongSelf.restartConnectionUpdatesIfNecessary()
                    if strongSelf.isScanning {
                        strongSelf.startScan()
                    }
                    return
                }
                Logger.debug("Connection failed: '\(error), \(peripheral.name)', \(peripheral.identifier.uuidString)")
                strongSelf.removedPeripherals.insert(peripheral.identifier)
                peripheral.terminate()
                strongSelf.connectedPeripherals.remove(peripheral.identifier)
                strongSelf.restartConnectionUpdatesIfNecessary()
                if strongSelf.isScanning {
                    strongSelf.startScan()
                }
                strongSelf.updateWhenActive()

            }
        }
    }

    func restartConnectionUpdatesIfNecessary() {
        guard peripheralsToConnect.isEmpty else {
            return
        }
        connectedPeripherals.removeAll()
        connectingPeripherals.removeAll()
        peripheralsToConnect.set(peripherals)
    }

    // MARK: Scanning

    func startScan() {
        guard !atDiscoveryLimit else { return }
        guard !Singletons.scanningManager.isScanning else { return }

        isScanning = true

        let scanOptions =  discoveryLimitReached ? [ String : Any]() : [CBCentralManagerScanOptionAllowDuplicatesKey : true]

        let future: FutureStream<Peripheral>
        let scanMode = ConfigStore.getScanMode()
        let scanDuration = ConfigStore.getScanDurationEnabled() ? Double(ConfigStore.getScanDuration()) : Double.infinity
        switch scanMode {
        case .promiscuous:
            future = Singletons.scanningManager.startScanning(capacity:10, timeout: scanDuration, options: scanOptions)
        case .service:
            let scannedServices = ConfigStore.getScannedServiceUUIDs()
            guard scannedServices.isEmpty == false else {
                present(UIAlertController.alert(message: "No scan services configured"), animated: true)
                return
            }
            future = Singletons.scanningManager.startScanning(forServiceUUIDs: scannedServices, capacity: 10, timeout: scanDuration, options: scanOptions)
        }
        future.onSuccess(completion: afterPeripheralDiscovered)
        future.onFailure(completion: afterTimeout)
    }

    func afterTimeout(error: Swift.Error) -> Void {
        guard let error = error as? CentralManagerError, error == .serviceScanTimeout else {
            return
        }
        Logger.debug("timeoutScan: timing out")
        stopScan()
        self.setScanButton()
        present(UIAlertController.alert(message: "Bluetooth scan timeout."), animated:true)
    }

    func afterPeripheralDiscovered(_ peripheral: Peripheral) -> Void {
        updateWhenActive()
        guard Singletons.discoveryManager.discoveredPeripherals[peripheral.identifier] == nil else {
            Logger.debug("Peripheral already discovered \(peripheral.name), \(peripheral.identifier.uuidString)")
            return
        }
        guard !removedPeripherals.contains(peripheral.identifier) else {
            Logger.debug("Peripheral has been removed \(peripheral.name), \(peripheral.identifier.uuidString)")
            return
        }
        guard Singletons.discoveryManager.retrievePeripherals(withIdentifiers: [peripheral.identifier]).first != nil else {
            Logger.debug("Discovered peripheral not found")
            return
        }
        Logger.debug("Discovered peripheral: '\(peripheral.name)', \(peripheral.identifier.uuidString)")
        peripheralsToConnect.push(peripheral.identifier)
        peripheralAdvertisments[peripheral.identifier] = peripheral.advertisements
        if atDiscoveryLimit {
            discoveryLimitReached = true
            Singletons.scanningManager.stopScanning()
        }
    }

    func stopScan() {
        if Singletons.scanningManager.isScanning {
            Singletons.scanningManager.stopScanning()
        }
        isScanning = false
        Singletons.discoveryManager.removeAllPeripherals()
        Singletons.scanningManager.removeAllPeripherals()
        connectingPeripherals.removeAll()
        connectedPeripherals.removeAll()
        discoveredPeripherals.removeAll()
        removedPeripherals.removeAll()
        peripheralsToConnect.removeAll()
        peripheralsToDisconnect.removeAll()
        updateWhenActive()
    }


    // MARK: Peripheral discovery

    func discoverPeripheral(_ peripheral: Peripheral) {
        guard peripheral.state == .connected else {
            return
        }
        guard !discoveredPeripherals.contains(peripheral.identifier) else {
            peripheralsToDisconnect.push(peripheral.identifier)
            return
        }
        let scanTimeout = TimeInterval(ConfigStore.getCharacteristicReadWriteTimeout())
        let peripheralDiscoveryFuture = peripheral.discoverAllServices(timeout: scanTimeout).flatMap { peripheral in
            peripheral.services.map { $0.discoverAllCharacteristics(timeout: scanTimeout) }.sequence()
        }
        peripheralDiscoveryFuture.onSuccess { [weak self] _ in
            self.forEach { strongSelf in
                strongSelf.discoveredPeripherals.insert(peripheral.identifier)
                strongSelf.peripheralsToDisconnect.push(peripheral.identifier)
                strongSelf.updateWhenActive()
            }
        }
        peripheralDiscoveryFuture.onFailure { [weak self] error in
            self.forEach { strongSelf in
                Logger.debug("Service discovery failed \(error), \(peripheral.name), \(peripheral.identifier.uuidString)")
                strongSelf.peripheralsToDisconnect.push(peripheral.identifier)
                strongSelf.updateWhenActive()
            }
        }
    }

    // MARK: UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        return atDiscoveryLimit ? ConfigStore.getMaximumPeripheralsDiscovered() : Singletons.discoveryManager.peripherals.count
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: MainStoryboard.peripheralCell, for: indexPath) as! PeripheralCell
        let peripheral = self.peripherals[indexPath.row]
        cell.nameLabel.text = peripheral.name
        if peripheral.state == .connected || peripheral.services.count > 0 {
            cell.nameLabel.textColor = UIColor.black
        } else {
            cell.nameLabel.textColor = UIColor.lightGray
        }
        if peripheral.state == .connected {
            cell.nameLabel.textColor = UIColor.black
            cell.stateLabel.text = "Connected"
            cell.stateLabel.textColor = UIColor(red:0.1, green:0.7, blue:0.1, alpha:0.5)
        } else if connectedPeripherals.contains(peripheral.identifier) && discoveredPeripherals.contains(peripheral.identifier) && connectingPeripherals.contains(peripheral.identifier) {
            cell.stateLabel.text = "Discovered"
            cell.stateLabel.textColor = UIColor(red:0.4, green:0.75, blue:1.0, alpha:0.5)
        } else if discoveredPeripherals.contains(peripheral.identifier) && connectingPeripherals.contains(peripheral.identifier) {
            cell.stateLabel.text = "Connecting"
            cell.stateLabel.textColor = UIColor(red:0.7, green:0.1, blue:0.1, alpha:0.5)
        } else if discoveredPeripherals.contains(peripheral.identifier) {
            cell.stateLabel.text = "Discovered"
            cell.stateLabel.textColor = UIColor(red:0.4, green:0.75, blue:1.0, alpha:0.5)
        } else if connectingPeripherals.contains(peripheral.identifier) {
            cell.stateLabel.text = "Connecting"
            cell.stateLabel.textColor = UIColor(red:0.7, green:0.1, blue:0.1, alpha:0.5)
        } else {
            cell.stateLabel.text = "Disconnected"
            cell.stateLabel.textColor = UIColor.lightGray
        }
        updateRSSI(peripheral: peripheral, cell: cell)
        cell.servicesLabel.text = "\(peripheral.services.count)"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        shouldUpdateConnections = false
        Singletons.scanningManager.stopScanning()
        disconnectConnectingPeripherals()
    }

    func updateRSSI(peripheral: Peripheral, cell: PeripheralCell) {
        guard let discoveredPeripheral = Singletons.scanningManager.discoveredPeripherals[peripheral.identifier] else {
            cell.rssiImage.image = #imageLiteral(resourceName: "RSSI-0")
            cell.rssiLabel.text = "NA"
            return
        }
        cell.rssiLabel.text = "\(discoveredPeripheral.RSSI)"
        let rssiImage: UIImage
        switch discoveredPeripheral.RSSI {
        case (-40)...(-1):
            rssiImage = #imageLiteral(resourceName: "RSSI-5")
        case (-55)...(-41):
            rssiImage = #imageLiteral(resourceName: "RSSI-4")
        case (-70)...(-56):
            rssiImage = #imageLiteral(resourceName: "RSSI-3")
        case (-85)...(-71):
            rssiImage = #imageLiteral(resourceName: "RSSI-2")
        case (-99)...(-86):
            rssiImage = #imageLiteral(resourceName: "RSSI-1")
        default:
            rssiImage = #imageLiteral(resourceName: "RSSI-0")
        }
        cell.rssiImage.image = rssiImage
    }
}
