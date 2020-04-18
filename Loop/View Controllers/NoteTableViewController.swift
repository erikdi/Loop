//
//  NoteTableViewController.swift
//  Loop
//
//  Copyright © 2016 LoopKit Authors. All rights reserved.
//

import Foundation
import UIKit
import LoopKit
import HealthKit
import LoopCore


final class NoteTableViewController: UITableViewController, IdentifiableClass {

    @IBOutlet weak var noteBox: UITextView!
    
    var saved = false
    var text = ""
    
    @IBAction func saveButton(_ sender: Any) {
        self.saved = true
        self.text = noteBox.text!
        self.performSegue(withIdentifier: "close", sender: nil)
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        super.prepare(for: segue, sender: sender)
        
        self.noteBox.becomeFirstResponder()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        self.noteBox.becomeFirstResponder()
    }
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        
        return true
    }
}
