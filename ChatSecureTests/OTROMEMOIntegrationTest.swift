//
//  OTROMEMOStreamTest.swift
//  ChatSecure
//
//  Created by David Chiles on 10/6/16.
//  Copyright © 2016 Chris Ballinger. All rights reserved.
//

import XCTest
import ChatSecureCore

struct TestUser {
    var account:OTRXMPPAccount
    var buddy:OTRBuddy
    var databaseManager:OTRDatabaseManager
    var signalOMEMOCoordinator:OTROMEMOSignalCoordinator
}

class OTROMEMOIntegrationTest: XCTestCase {
    
    // This is teh 'remote' user in this setup
    var aliceUser:TestUser?
    var aliceOmemoModule:OTROMEMOTestModule?
    // This is the 'local' user
    var bobUser:TestUser?
    var bobOmemoModule:OTROMEMOTestModule?
    
    override func setUp() {
        super.setUp()
        
        FileManager.default.clearDirectory(OTRTestDatabaseManager.yapDatabaseDirectory())
    }
    
    /** Create two user accounts and save each other as buddies */
    func setupTwoAccounts(_ name:String) {
        let aliceName = "\(name)-alice"
        let bobName = "\(name)-bob"
        self.aliceUser = self.setupUserWithName(aliceName,buddyName: bobName)
        self.aliceOmemoModule = OTROMEMOTestModule(omemoStorage: self.aliceUser!.signalOMEMOCoordinator, xmlNamespace: .conversationsLegacy, dispatchQueue: nil)
        self.aliceOmemoModule?.addDelegate(self.aliceUser!.signalOMEMOCoordinator, delegateQueue: self.aliceUser!.signalOMEMOCoordinator.workQueue)
        self.aliceOmemoModule?.thisUser = aliceUser
        
        self.bobUser = self.setupUserWithName(bobName,buddyName: aliceName)
        self.bobOmemoModule = OTROMEMOTestModule(omemoStorage: self.bobUser!.signalOMEMOCoordinator, xmlNamespace: .conversationsLegacy, dispatchQueue: nil)
        self.bobOmemoModule?.addDelegate(self.bobUser!.signalOMEMOCoordinator, delegateQueue: self.bobUser!.signalOMEMOCoordinator.workQueue)
        self.bobOmemoModule?.thisUser = bobUser
        
        
        self.aliceOmemoModule?.otherUser = self.bobOmemoModule
        self.bobOmemoModule?.otherUser = self.aliceOmemoModule
        
    }
    
    /** 
     Setup up use rwith name and a buddy with name 
     Creates:
     1. A database for the user.
     2. An account and buddy for the suesr.
     3. An OTROMEMOSignalCoordinator to do all the signal functionality.
     */
    func setupUserWithName(_ name:String, buddyName:String) -> TestUser {
        let databaseManager = OTRTestDatabaseManager.setupDatabaseWithName(name)
        let account = TestXMPPAccount(username: "\(name)@fake.com", accountType: .jabber)!
        
        let buddy = OTRBuddy()!
        buddy.username = "\(buddyName)@fake.com"
        buddy.accountUniqueId = account.uniqueId
        
        databaseManager.readWriteDatabaseConnection?.readWrite( { (transaction) in
            account.save(with:transaction)
            buddy.save(with:transaction)
        })
        let signalOMEMOCoordinator = try! OTROMEMOSignalCoordinator(accountYapKey: account.uniqueId, databaseConnection: databaseManager.readWriteDatabaseConnection!)
        return TestUser(account: account,buddy:buddy, databaseManager: databaseManager, signalOMEMOCoordinator: signalOMEMOCoordinator)
    }
    
    /**
     1. Setup two accounts
     2. Authenticate the stream. Should receive devices for our buddy.
     3. Check that we support OMEMO for that buddy. ✔︎
     */
    func testDeviceSetup() {
        self.setupTwoAccounts(#function)
        self.bobOmemoModule?.xmppStreamDidAuthenticate(nil)
        let buddy = self.bobUser!.buddy
        let connection = self.bobUser?.databaseManager.readOnlyDatabaseConnection
        connection?.read({ (transaction) in
            let devices = OTROMEMODevice.allDevices(forParentKey: buddy.uniqueId, collection: type(of: buddy).collection(), transaction: transaction)
            XCTAssert(devices.count > 0)
        })
    }
    
    /**
     1. Setup two accounts
     2. Authenticate the stream. Should receive devices for our buddy.
     3. Send a message to the buddy. This should trigger fetching the buddy's bundle to create a session.
     4. Ensure that encryption went correctly. ✔︎
     5. Ensure that that alice received the message. ✔︎
    */
    func testFetchingBundleSetup() {
        self.setupTwoAccounts(#function)
        self.bobOmemoModule?.xmppStreamDidAuthenticate(nil)
        let expectation = self.expectation(description: "Sending Message")
        let messageText = "This is message from Bob to Alice"
        self.bobUser!.signalOMEMOCoordinator.encryptAndSendMessage(messageText, buddyYapKey: self.bobUser!.buddy.uniqueId, messageId: "message1") { (success, error) in
            
            XCTAssertTrue(success,"Able to send message")
            XCTAssertNil(error,"Error Sending \(error)")
            
            expectation.fulfill()
        }
        
        self.waitForExpectations(timeout: 30, handler: nil)
        
        var messageFound = false
        self.aliceUser?.databaseManager.readWriteDatabaseConnection?.read({ (transaction) in
            transaction.enumerateKeysAndObjects(inCollection: OTRBaseMessage.collection(), using: { (key, object, stop) in
                if let message = object as? OTRBaseMessage {
                    XCTAssertEqual(message.text, messageText)
                    messageFound = true
                }
                
            })
            
            transaction.enumerateKeysAndObjects(inCollection: OTROMEMODevice.collection(), using: { (key, object, stop) in
                let device = object as! OTROMEMODevice
                XCTAssertNotNil(device.lastSeenDate)
            })
            
        })
        XCTAssertTrue(messageFound,"Found message")
    }
    
    func testRemoveDevice() {
        self.setupTwoAccounts(#function)
        self.bobOmemoModule?.xmppStreamDidAuthenticate(nil)
        let expectation = self.expectation(description: "Remove Devices")
        let deviceNumber = NSNumber(value: 5 as Int32)
        let device = OTROMEMODevice(deviceId: deviceNumber, trustLevel: OMEMOTrustLevel.trustedTofu, parentKey: self.bobUser!.account.uniqueId, parentCollection: OTRAccount.collection(), publicIdentityKeyData: nil, lastSeenDate: nil)
        
        self.bobUser?.databaseManager.readWriteDatabaseConnection?.readWrite({ (transaction) in
            
            device.save(with:transaction)
        })
        self.bobUser?.signalOMEMOCoordinator.removeDevice([device], completion: { (result) in
            XCTAssertTrue(result)
            self.bobUser!.databaseManager.readOnlyDatabaseConnection?.read({ (transaction) in
                let yapKey = OTROMEMODevice.yapKey(withDeviceId: deviceNumber, parentKey: self.bobUser!.account.uniqueId, parentCollection: OTRAccount.collection())
                let device = OTROMEMODevice.fetchObject(withUniqueID: yapKey, transaction: transaction)
                XCTAssertNil(device)
            })
            
             expectation.fulfill()
        })
        
        self.waitForExpectations(timeout: 10, handler: nil)
        
    }
}
