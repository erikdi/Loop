//
//  FoodCollectionViewCell.swift
//  Loop
//
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import Foundation
import UIKit

final class FoodCollectionViewCell: UICollectionViewCell {

    @IBOutlet weak var imageView: UIImageView!
    @IBOutlet weak var foodLabel: UILabel?
    
    @IBOutlet weak var carbLabel: UILabel?
    @IBOutlet weak var emojiLabel: UILabel?

    override func prepareForReuse() {
        imageView.image = nil
        backgroundColor = UIColor.lightGray
        if foodLabel != nil {
            foodLabel!.text = "???"
        }
        if carbLabel != nil {
            carbLabel!.text = ""
        }
        if emojiLabel != nil {
            emojiLabel!.text = ""
        }
    }
}
