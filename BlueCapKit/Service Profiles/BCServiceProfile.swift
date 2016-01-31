//
//  BCServiceProfile.swift
//  BlueCap
//
//  Created by Troy Stribling on 6/21/14.
//  Copyright (c) 2014 Troy Stribling. The MIT License (MIT).
//

import Foundation
import CoreBluetooth

// MARK: - BCServiceProfile -
public class BCServiceProfile {
    
    internal var characteristicProfiles = [CBUUID: CBCharacteristicProfile]()

    public let uuid : CBUUID
    public let name : String
    public let tag  : String
    
    public var characteristics : [CharacteristicProfile] {
        return Array(self.characteristicProfiles.values)
    }
    
    public var characteristic : [CBUUID:CharacteristicProfile] {
        return self.characteristicProfiles
    }
    
    public init(uuid:String, name:String, tag:String = "Miscellaneous") {
        self.name = name
        self.uuid = CBUUID(string:uuid)
        self.tag = tag
    }
    
    public convenience init(uuid:String) {
        self.init(uuid:uuid, name:"Unknown")
    }

    public func addCharacteristic(characteristicProfile: CharacteristicProfile) {
        BCLogger.debug("name=\(characteristicProfile.name), uuid=\(characteristicProfile.uuid.UUIDString)")
        self.characteristicProfiles[characteristicProfile.uuid] = characteristicProfile
    }
    
}

public class ConfiguredServiceProfile<Config: BCServiceConfigurable> : BCServiceProfile {
    
    public init() {
        super.init(uuid: Config.uuid, name: Config.name, tag: Config.tag)
    }
    
}