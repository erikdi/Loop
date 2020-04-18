//
//  GitVersionInformation.swift
//  Loop2
//
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import Foundation

struct GitVersionInformation {
    let dict : [String:String]
}

extension GitVersionInformation {
    init() {
        var myDict: [String: String]?
        if let path = Bundle.main.path(forResource: "GitInfo", ofType: "plist") {
            myDict = NSDictionary(contentsOfFile: path) as? [String: String]
        }
        if let d = myDict {
            dict = d
        } else {
            dict = [:]
        }
    }

    var description : String {
        guard
            let buildDate = dict["BUILD_CURRENT_DATE"],
            let _ = dict["GIT_BRANCH"],
            let commit = dict["GIT_COMMIT_HASH"],
            let describe = dict["GIT_DESCRIBE"] else {
                return "<Not all properties set in GitInfo>"
        }
        return "\(describe) \(commit) \(buildDate)"
    }
}
