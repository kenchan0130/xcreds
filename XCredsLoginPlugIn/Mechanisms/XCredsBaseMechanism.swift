import Cocoa
import OpenDirectory

protocol XCredsMechanismProtocol {
    func allowLogin()
    func denyLogin()
    func setContextString(type: String, value: String)
    func setHint(type: HintType, hint: Any)
    func reload()
}
@objc class XCredsBaseMechanism: NSObject, XCredsMechanismProtocol {
    func reload() {
        fatalError()
    }

    let mechCallbacks: AuthorizationCallbacks
    let mechEngine: AuthorizationEngineRef
    let mech: MechanismRecord?
    @objc init(mechanism: UnsafePointer<MechanismRecord>) {
        TCSLogWithMark("\(#function) \(#file):\(#line)")
        self.mech = mechanism.pointee
        self.mechCallbacks = mechanism.pointee.fPlugin.pointee.fCallbacks.pointee
        self.mechEngine = mechanism.pointee.fEngine

        super.init()
        setupPrefs()

    }
    func run(){
        fatalError("superclass must implement")
    }
    func setupPrefs(){
        UserDefaults.standard.addSuite(named: "com.twocanoes.xcreds")
        let defaultsPath = Bundle(for: type(of: self)).path(forResource: "defaults", ofType: "plist")

        if let defaultsPath = defaultsPath {

            let defaultsDict = NSDictionary(contentsOfFile: defaultsPath)
            UserDefaults.standard.register(defaults: defaultsDict as! [String : Any])
        }

        let allBundles = Bundle.allBundles

        for currentBundle in allBundles {
            if currentBundle.bundlePath.contains("XCreds") {
                let infoPlist = currentBundle.infoDictionary
                if let infoPlist = infoPlist, let build = infoPlist["CFBundleVersion"] {
                    TCSLogWithMark("-------------------------------------")
                    TCSLogWithMark("XCreds Login Build Number: \(build)")
                    TCSLogWithMark("-------------------------------------")
                    break
                }

            }
        }

    }
    var xcredsPass: String? {
        get {
            guard let userPass = getHint(type: .pass) as? String else {
                return nil
            }
            os_log("Computed xcredsPass accessed: %@", log: noLoMechlog, type: .debug)
            return userPass
        }
    }
    var xcredsFirst: String? {
        get {
            guard let firstName = getHint(type: .firstName) as? String else {
                return nil
            }
            os_log("Computed nomadFirst accessed: %{public}@", log: noLoMechlog, type: .debug, firstName)
            return firstName
        }
    }

    var xcredsLast: String? {
        get {
            guard let lastName = getHint(type: .lastName) as? String else {
                return nil
            }
            os_log("Computed nomadLast accessed: %{public}@", log: noLoMechlog, type: .debug, lastName)
            return lastName
        }
    }
    var xcredsUser: String? {
        get {
            guard let userName = getHint(type: .user) as? String else {
                TCSLogWithMark("no username!")

                return nil
            }
            return userName
        }
    }
    var usernameContext: String? {
        get {
            var value : UnsafePointer<AuthorizationValue>? = nil
            var flags = AuthorizationContextFlags()
            var err: OSStatus = noErr
            err = mechCallbacks.GetContextValue(
                mechEngine, kAuthorizationEnvironmentUsername, &flags, &value)

            if err != errSecSuccess {
                return nil
            }

            guard let username = NSString.init(bytes: value!.pointee.data!,
                                               length: value!.pointee.length,
                                               encoding: String.Encoding.utf8.rawValue)
                else { return nil }

            return username.replacingOccurrences(of: "\0", with: "") as String
        }
    }

    var passwordContext: String? {
        get {
            var value : UnsafePointer<AuthorizationValue>? = nil
            var flags = AuthorizationContextFlags()
            var err: OSStatus = noErr
            err = mechCallbacks.GetContextValue(
                mechEngine, kAuthorizationEnvironmentPassword, &flags, &value)

            if err != errSecSuccess {
                return nil
            }
            guard let pass = NSString.init(bytes: value!.pointee.data!,
                                           length: value!.pointee.length,
                                           encoding: String.Encoding.utf8.rawValue)
                else { return nil }

            return pass.replacingOccurrences(of: "\0", with: "") as String
        }
    }


    func allowLogin() {
        TCSLogWithMark("\(#function) \(#file):\(#line)")
        let error = mechCallbacks.SetResult(mechEngine, .allow)
        if error != noErr {
            TCSLogWithMark("Error: \(error)")
        }
    }

    // disallow login
    func denyLogin() {
        TCSLogWithMark("\(#function) \(#file):\(#line)")

        let error = mechCallbacks.SetResult(mechEngine, .deny)
        if error != noErr {
            TCSLogWithMark("Error: \(error)")

        }
    }

    func setHint(type: HintType, hint: Any) {
        guard (hint is String || hint is [String] || hint is Bool) else {
            TCSLogWithMark("Login Set hint failed: data type of hint is not supported")
            return
        }
        let data = NSKeyedArchiver.archivedData(withRootObject: hint)
        var value = AuthorizationValue(length: data.count, data: UnsafeMutableRawPointer(mutating: (data as NSData).bytes.bindMemory(to: Void.self, capacity: data.count)))

        let err = mechCallbacks.SetHintValue((mech?.fEngine)!, type.rawValue, &value)
        guard err == errSecSuccess else {
            TCSLogWithMark("NoMAD Login Set hint failed with: %{public}@")
            return
        }
    }
    var nomadGroups: [String]? {
        get {
            guard let userGroups = getHint(type: .groups) as? [String] else {
                os_log("noMADGroups value is empty", log: noLoMechlog, type: .debug)
                return nil
            }
            os_log("Computed nomadgroups accessed: %{public}@", log: noLoMechlog, type: .debug)
            return userGroups
        }
    }

    func getHint(type: HintType) -> Any? {
        var value : UnsafePointer<AuthorizationValue>? = nil
        var err: OSStatus = noErr
        err = mechCallbacks.GetHintValue((mech?.fEngine)!, type.rawValue, &value)
        if err != errSecSuccess {
            TCSLogWithMark("Couldn't retrieve hint value: \(type.rawValue)")
            return nil
        }
        let outputdata = Data.init(bytes: value!.pointee.data!, count: value!.pointee.length)
        guard let result = NSKeyedUnarchiver.unarchiveObject(with: outputdata)
            else {
            TCSLogWithMark("Couldn't unpack hint value: %{public}@")
                return nil
        }
        return result
    }

    /// Adds a new alias to an existing local record
    ///
    /// - Parameters:
    ///   - name: the shortname of the user to check as a `String`.
    ///   - alias: The password of the user to check as a `String`.
    /// - Returns: `true` if user:pass combo is valid, false if not.
    class func addAlias(name: String, alias: String) -> Bool {
        os_log("Checking for local username", log: noLoMechlog, type: .error)
        var records = [ODRecord]()
        let odsession = ODSession.default()
        do {
            let node = try ODNode.init(session: odsession, type: ODNodeType(kODNodeTypeLocalNodes))
            let query = try ODQuery.init(node: node, forRecordTypes: kODRecordTypeUsers, attribute: kODAttributeTypeRecordName, matchType: ODMatchType(kODMatchEqualTo), queryValues: name, returnAttributes: kODAttributeTypeAllAttributes, maximumResults: 0)
            records = try query.resultsAllowingPartial(false) as! [ODRecord]
        } catch {
            let errorText = error.localizedDescription
            os_log("ODError while trying to check for local user: %{public}@", log: noLoMechlog, type: .error, errorText)
            return false
        }

        let isLocal = records.isEmpty ? false : true
        os_log("Results of local user check  %{public}@", log: noLoMechlog, type: .error, isLocal.description)

        if !isLocal {
            return isLocal
        }

        // now to update the alias
        do {
                if let currentAlias = try records.first?.values(forAttribute: kODAttributeTypeRecordName) as? [String] {
                    if !currentAlias.contains(alias) {
                      try records.first?.addValue(alias, toAttribute: kODAttributeTypeRecordName)
                    }
                } else {
                    try records.first?.addValue(alias, toAttribute: kODAttributeTypeRecordName)
                }
        } catch {
            os_log("Unable to add alias to record")
            return false
        }

        return true
    }

    /// Updates a timestamp on a local account
    ///
    /// - Parameters:
    ///   - name: the shortname of the user to check as a `String`.
    ///   - time: The time to add  as a `String`.
    /// - Returns: `true` if time attribute can be added, false if not.
    class func updateSignIn(name: String, time: AnyObject ) -> Bool {
        os_log("Checking for local username", log: noLoMechlog, type: .default)
        var records = [ODRecord]()
        let odsession = ODSession.default()
        do {
            let node = try ODNode.init(session: odsession, type: ODNodeType(kODNodeTypeLocalNodes))
            let query = try ODQuery.init(node: node, forRecordTypes: kODRecordTypeUsers, attribute: kODAttributeTypeRecordName, matchType: ODMatchType(kODMatchEqualTo), queryValues: name, returnAttributes: kODAttributeTypeAllAttributes, maximumResults: 0)
            records = try query.resultsAllowingPartial(false) as! [ODRecord]
        } catch {
            let errorText = error.localizedDescription
            os_log("ODError while trying to check for local user: %{public}@", log: noLoMechlog, type: .error, errorText)
            return false
        }

        let isLocal = records.isEmpty ? false : true
        os_log("Results of local user check %{public}@", log: noLoMechlog, type: .default, isLocal.description)

        if !isLocal {
            return isLocal
        }

        // now to update the attribute

        do {
            try records.first?.setValue(time, forAttribute: kODAttributeNetworkSignIn)
        } catch {
            os_log("Unable to add sign in time to record", log: noLoMechlog, type: .error)
            return false
        }

        return true
    }
    /// Set one of the known `AuthorizationTags` values to be used during mechanism evaluation.
    ///
    /// - Parameters:
    ///   - type: A `String` constant from AuthorizationTags.h representing the value to set.
    ///   - value: A `String` value of the context value to set.
    func setContextString(type: String, value: String) {
        let tempdata = value + "\0"
        let data = tempdata.data(using: .utf8)
        var value = AuthorizationValue(length: (data?.count)!, data: UnsafeMutableRawPointer(mutating: (data! as NSData).bytes.bindMemory(to: Void.self, capacity: (data?.count)!)))
        let err = mechCallbacks.SetContextValue((mech?.fEngine)!, type, .extractable, &value)
        guard err == errSecSuccess else {
            TCSLogWithMark("Set context value failed with: %{public}@")
            return
        }
    }

    func getContextString(type: String) -> String? {
        var value: UnsafePointer<AuthorizationValue>?
        var flags = AuthorizationContextFlags()
        let err = mechCallbacks.GetContextValue((mech?.fEngine)!, type, &flags, &value)
        if err != errSecSuccess {
            TCSLogWithMark("Couldn't retrieve context value: %{public}@")
            return nil
        }
        if type == "longname" {
            return String.init(bytesNoCopy: value!.pointee.data!, length: value!.pointee.length, encoding: .utf8, freeWhenDone: false)
        } else {
            let item = Data.init(bytes: value!.pointee.data!, count: value!.pointee.length)
            TCSLogWithMark("get context error: %{public}@")
        }

        return nil
    }
    //MARK: - Directory Service Utilities

    /// Checks to see if a given user exits in the DSLocal OD node.
    ///
    /// - Parameter name: The shortname of the user to check as a `String`.
    /// - Returns: `true` if the user already exists locally. Otherwise `false`.
    class func checkForLocalUser(name: String) -> Bool {
        os_log("Checking for local username", log: noLoMechlog, type: .debug)
        var records = [ODRecord]()
        let odsession = ODSession.default()
        do {
            let node = try ODNode.init(session: odsession, type: ODNodeType(kODNodeTypeLocalNodes))
            let query = try ODQuery.init(node: node, forRecordTypes: kODRecordTypeUsers, attribute: kODAttributeTypeRecordName, matchType: ODMatchType(kODMatchEqualTo), queryValues: name, returnAttributes: kODAttributeTypeAllAttributes, maximumResults: 0)
            records = try query.resultsAllowingPartial(false) as! [ODRecord]
        } catch {
            let errorText = error.localizedDescription
            os_log("ODError while trying to check for local user: %{public}@", log: noLoMechlog, type: .error, errorText)
            return false
        }
        let isLocal = records.isEmpty ? false : true
//        os_log("Results of local user check %{public}@", log: noLoMechlog, type: .debug, isLocal.description)
        return isLocal
    }

    class func verifyUser(name: String, auth: String) -> Bool {
        os_log("Finding user record", log: noLoMechlog, type: .debug)
        var records = [ODRecord]()
        let odsession = ODSession.default()
        var isValid = false
        do {
            let node = try ODNode.init(session: odsession, type: ODNodeType(kODNodeTypeLocalNodes))
            let query = try ODQuery.init(node: node, forRecordTypes: kODRecordTypeUsers, attribute: kODAttributeTypeRecordName, matchType: ODMatchType(kODMatchEqualTo), queryValues: name, returnAttributes: kODAttributeTypeAllAttributes, maximumResults: 0)
            records = try query.resultsAllowingPartial(false) as! [ODRecord]
            isValid = ((try records.first?.verifyPassword(auth)) != nil)
        } catch {
            let errorText = error.localizedDescription
            TCSLogWithMark("ODError while trying to check for local user: \(errorText)")
            return false
        }
        return isValid
    }


    /// Gets shortname from a UUID
    ///
    /// - Parameters:
    ///   - uuid: the uuid of the user to check as a `String`.
    /// - Returns: shortname of the user or nil.
    class func getShortname(uuid: String) -> String? {

        os_log("Checking for username from UUID", log: noLoMechlog, type: .debug)
        var records = [ODRecord]()
        let odsession = ODSession.default()
        do {
            let node = try ODNode.init(session: odsession, type: ODNodeType(kODNodeTypeLocalNodes))
            let query = try ODQuery.init(node: node, forRecordTypes: kODRecordTypeUsers, attribute: kODAttributeTypeGUID, matchType: ODMatchType(kODMatchEqualTo), queryValues: uuid, returnAttributes: kODAttributeTypeAllAttributes, maximumResults: 0)
            records = try query.resultsAllowingPartial(false) as! [ODRecord]
        } catch {
            let errorText = error.localizedDescription
//            os_log("ODError while trying to check for local user: %{public}@", log: noLoMechlog, type: .error, errorText)
            return nil
        }

        if records.count != 1 {
            return nil
        } else {
            return records.first?.recordName
        }
    }

}
