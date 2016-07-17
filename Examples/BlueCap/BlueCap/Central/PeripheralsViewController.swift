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

class PeripheralsViewController : UITableViewController {

    var stopScanBarButtonItem: UIBarButtonItem!
    var startScanBarButtonItem: UIBarButtonItem!

    var scanStatus = false
    var shouldUpdatePeripheralConnectionStatus = false
    var peripheralConnectionStatus = [NSUUID : Bool]()
    var connectionFuture: FutureStream<(peripheral: Peripheral, connectionEvent: ConnectionEvent)>!

    var reachedDiscoveryLimit: Bool {
        return Singletons.centralManager.peripherals.count >= ConfigStore.getMaximumPeripheralsDiscovered()
    }

    var peripheralsSortedByRSSI: [Peripheral] {
        return Singletons.centralManager.peripherals.sort() { (p1, p2) -> Bool in
            if p1.RSSI == 127 && p2.RSSI != 127 {
                return false
            }  else if p1.RSSI != 127 && p2.RSSI == 127 {
                return true
            } else if p1.RSSI == 127 && p2.RSSI == 127 {
                return true
            } else {
                return p1.RSSI >= p2.RSSI
            }
        }
    }

    var peripherals: [Peripheral] {
        if ConfigStore.getPeripheralSortOrder() == .DiscoveryDate {
            return Singletons.centralManager.peripherals
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
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: "", style: .Plain, target: nil, action: nil)
        self.stopScanBarButtonItem = UIBarButtonItem(barButtonSystemItem: .Stop, target: self, action: #selector(PeripheralsViewController.toggleScan(_:)))
        self.startScanBarButtonItem = UIBarButtonItem(title: "Scan", style: UIBarButtonItemStyle.Plain, target: self, action: #selector(PeripheralsViewController.toggleScan(_:)))
        self.styleUIBarButton(self.startScanBarButtonItem)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.styleNavigationBar()
        self.setScanButton()
    }
    
    override func viewDidAppear(animated: Bool) {
        super.viewDidAppear(animated)
        self.shouldUpdatePeripheralConnectionStatus = true
        self.updatePeripheralConnectionsIfNeeded()
        self.startPolllingRSSIForPeripherals()
        NSNotificationCenter.defaultCenter().addObserver(self, selector:#selector(PeripheralsViewController.didBecomeActive), name: UIApplicationDidBecomeActiveNotification, object:nil)
        NSNotificationCenter.defaultCenter().addObserver(self, selector:#selector(PeripheralsViewController.didEnterBackground), name: UIApplicationDidEnterBackgroundNotification, object:nil)
        self.setScanButton()
    }

    override func viewDidDisappear(animated: Bool) {
        super.viewWillDisappear(animated)
        self.shouldUpdatePeripheralConnectionStatus = false
        self.stopPollingRSSIForPeripherals()
        NSNotificationCenter.defaultCenter().removeObserver(self)
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
    override func prepareForSegue(segue: UIStoryboardSegue, sender: AnyObject!) {
        if segue.identifier == MainStoryboard.peripheralSegue {
            if let selectedIndex = self.tableView.indexPathForCell(sender as! UITableViewCell) {
                let viewController = segue.destinationViewController as! PeripheralViewController
                viewController.peripheral = self.peripherals[selectedIndex.row]
            }
        }
    }
    
    // actions
    func toggleScan(sender: AnyObject) {
        if !Singletons.beaconManager.isMonitoring {
            if self.scanStatus {
                Logger.debug("Scan toggled off")
                self.stopScanning()
            } else {
                Logger.debug("Scan toggled on")
                Singletons.centralManager.whenPowerOn().onSuccess {
                    self.startScan()
                    self.setScanButton()
                    self.updatePeripheralConnectionsIfNeeded()
                }
            }
        } else {
            self.presentViewController(UIAlertController.alertWithMessage("iBeacon monitoring is active. Cannot scan and monitor iBeacons simutaneously. Stop iBeacon monitoring to start scan"), animated:true, completion:nil)
        }
    }

    func stopScanning() {
        if Singletons.centralManager.isScanning {
            Singletons.centralManager.stopScanning()
        }
        self.scanStatus = false
        self.stopPollingRSSIForPeripherals()
        Singletons.centralManager.disconnectAllPeripherals()
        Singletons.centralManager.removeAllPeripherals()
        self.peripheralConnectionStatus.removeAll()
        self.setScanButton()
        self.updateWhenActive()
    }

    // utils
    func didBecomeActive() {
        Logger.debug()
        self.tableView.reloadData()
        self.setScanButton()
    }

    func didEnterBackground() {
        Logger.debug()
        self.stopScanning()
        self.peripheralConnectionStatus.removeAll()
    }

    func setScanButton() {
        if self.scanStatus {
            self.navigationItem.setLeftBarButtonItem(self.stopScanBarButtonItem, animated:false)
        } else {
            self.navigationItem.setLeftBarButtonItem(self.startScanBarButtonItem, animated:false)
        }
    }

    func updatePeripheralConnections() {
        let peripherals = self.peripheralsSortedByRSSI
        let maxConnections = ConfigStore.getMaximumPeripheralsConnected()
        for i in 0..<peripherals.count {
            let peripheral = peripherals[i]
            if let connectionStatus = self.peripheralConnectionStatus[peripheral.identifier] {
                if i < maxConnections {
                    if !connectionStatus && peripheral.state == .Disconnected {
                        Logger.debug("Connecting peripheral: '\(peripheral.name)', \(peripheral.identifier.UUIDString)")
                        self.connect(peripheral)
                    }
                } else {
                    if connectionStatus {
                        Logger.debug("Disconnecting peripheral: '\(peripheral.name)', \(peripheral.identifier.UUIDString)")
                        peripheral.disconnect()
                    }
                }
            }
        }
    }

    func updatePeripheralConnectionsIfNeeded() {
        guard self.shouldUpdatePeripheralConnectionStatus && self.scanStatus else {
            return
        }
        Queue.main.delay(Params.updateConnectionsInterval) { [unowned self] in
            Logger.debug("update connections triggered")
            self.updatePeripheralConnections()
            self.updateWhenActive()
            self.updatePeripheralConnectionsIfNeeded()
        }
    }

    func startPollingRSSIForPeripheral(peripheral: Peripheral) {
        guard self.shouldUpdatePeripheralConnectionStatus else {
            return
        }
        peripheral.startPollingRSSI(Params.peripheralsViewRSSIPollingInterval, capacity: Params.peripheralRSSIFutureCapacity)
    }

    func startPolllingRSSIForPeripherals() {
        for peripheral in Singletons.centralManager.peripherals {
            guard let connectionStatus = self.peripheralConnectionStatus[peripheral.identifier] where connectionStatus else {
                continue
            }
            self.startPollingRSSIForPeripheral(peripheral)
        }
    }

    func stopPollingRSSIForPeripherals() {
        for peripheral in Singletons.centralManager.peripherals {
            peripheral.stopPollingRSSI()
        }
    }

    func connect(peripheral: Peripheral) {
        Logger.debug("Connect peripheral: '\(peripheral.name)'', \(peripheral.identifier.UUIDString)")
        let maxTimeouts = ConfigStore.getPeripheralMaximumTimeoutsEnabled() ? ConfigStore.getPeripheralMaximumTimeouts() : UInt.max
        let maxDisconnections = ConfigStore.getPeripheralMaximumDisconnectionsEnabled() ? ConfigStore.getPeripheralMaximumDisconnections() : UInt.max
        let connectionTimeout = ConfigStore.getPeripheralConnectionTimeoutEnabled() ? Double(ConfigStore.getPeripheralConnectionTimeout()) : Double.infinity
        connectionFuture = peripheral.connect(10, timeoutRetries: maxTimeouts, disconnectRetries: maxDisconnections, connectionTimeout: connectionTimeout)
        connectionFuture.onSuccess { (peripheral, connectionEvent) in
            switch connectionEvent {
            case .Connect:
                Logger.debug("Connected peripheral: '\(peripheral.name)', \(peripheral.identifier.UUIDString)")
                Notify.withMessage("Connected peripheral: '\(peripheral.name)', \(peripheral.identifier.UUIDString)")
                self.startPollingRSSIForPeripheral(peripheral)
                self.peripheralConnectionStatus[peripheral.identifier] = true
                self.updateWhenActive()
            case .Timeout:
                Logger.debug("Timeout: '\(peripheral.name)', \(peripheral.identifier.UUIDString)")
                peripheral.stopPollingRSSI()
                self.reconnectIfNecessary(peripheral)
                self.updateWhenActive()
            case .Disconnect:
                Logger.debug("Disconnected peripheral: '\(peripheral.name)', \(peripheral.identifier.UUIDString)")
                Notify.withMessage("Disconnected peripheral: '\(peripheral.name)'")
                peripheral.stopPollingRSSI()
                self.reconnectIfNecessary(peripheral)
                self.updateWhenActive()
            case .ForceDisconnect:
                Logger.debug("Force disconnection of: '\(peripheral.name)', \(peripheral.identifier.UUIDString)")
                Notify.withMessage("Force disconnection of: '\(peripheral.name), \(peripheral.identifier.UUIDString)'")
                self.reconnectIfNecessary(peripheral)
                self.updateWhenActive()
            case .GiveUp:
                Logger.debug("GiveUp: '\(peripheral.name)', \(peripheral.identifier.UUIDString)")
                peripheral.stopPollingRSSI()
                self.peripheralConnectionStatus.removeValueForKey(peripheral.identifier)
                peripheral.terminate()
                self.startScan()
                self.updateWhenActive()
            }
        }
        connectionFuture.onFailure { error in
            peripheral.stopPollingRSSI()
            self.reconnectIfNecessary(peripheral)
            self.updateWhenActive()
        }
    }

    func reconnectIfNecessary(peripheral: Peripheral) {
        if let status = self.peripheralConnectionStatus[peripheral.identifier] where status {
            peripheral.reconnect(1.0)
        }
    }
    
    func startScan() {
        guard self.reachedDiscoveryLimit == false else {
            return
        }
        self.scanStatus = true
        let scanMode = ConfigStore.getScanMode()
        let afterPeripheralDiscovered = { (peripheral: Peripheral) -> Void in
            if Singletons.centralManager.peripherals.contains(peripheral) {
                Logger.debug("Discovered peripheral: '\(peripheral.name)', \(peripheral.identifier.UUIDString)")
                Notify.withMessage("Discovered peripheral '\(peripheral.name)'")
                self.updateWhenActive()
                self.peripheralConnectionStatus[peripheral.identifier] = false
                if self.reachedDiscoveryLimit {
                    Singletons.centralManager.stopScanning()
                }
                self.updatePeripheralConnections()
            }
        }
        let afterTimeout = { (error: NSError) -> Void in
            if error.domain == BCError.domain && error.code == BCError.centralPeripheralScanTimeout.code {
                Logger.debug("timeoutScan: timing out")
                Singletons.centralManager.stopScanning()
                self.setScanButton()
            }
        }

        // Promiscuous Scan Enabled
        var future: FutureStream<Peripheral>
        let scanTimeout = ConfigStore.getScanTimeoutEnabled() ? Double(ConfigStore.getScanTimeout()) : Double.infinity
        switch scanMode {
        case .Promiscuous:
            // Promiscuous Scan with Timeout Enabled
            future = Singletons.centralManager.startScanning(10, timeout: scanTimeout)
            future.onSuccess(afterPeripheralDiscovered)
            future.onFailure(afterTimeout)
        case .Service:
            let scannedServices = ConfigStore.getScannedServiceUUIDs()
            if scannedServices.isEmpty {
                self.presentViewController(UIAlertController.alertWithMessage("No scan services configured"), animated: true, completion: nil)
            } else {
                future = Singletons.centralManager.startScanningForServiceUUIDs(scannedServices, capacity: 10, timeout: scanTimeout)
                future.onSuccess(afterPeripheralDiscovered)
                future.onFailure(afterTimeout)
            }
        }
    }

    // UITableViewDataSource
    override func numberOfSectionsInTableView(tableView: UITableView) -> Int {
        return 1
    }
    
    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        return Singletons.centralManager.peripherals.count
    }
    
    override func tableView(tableView: UITableView, cellForRowAtIndexPath indexPath: NSIndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCellWithIdentifier(MainStoryboard.peripheralCell, forIndexPath: indexPath) as! PeripheralCell
        let peripheral = self.peripherals[indexPath.row]
        cell.nameLabel.text = peripheral.name
        cell.accessoryType = .None
        if peripheral.state == .Connected {
            cell.nameLabel.textColor = UIColor.blackColor()
            cell.stateLabel.text = "Connected"
            cell.stateLabel.textColor = UIColor(red:0.1, green:0.7, blue:0.1, alpha:0.5)
        } else {
            cell.nameLabel.textColor = UIColor.lightGrayColor()
            cell.stateLabel.text = "Disconnected"
            cell.stateLabel.textColor = UIColor.lightGrayColor()
        }
        cell.rssiLabel.text = "\(peripheral.RSSI)"
        return cell
    }
}