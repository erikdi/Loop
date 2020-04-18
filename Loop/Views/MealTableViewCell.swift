//
//  TitleSubtitleTableViewCell.swift
//  Loop
//
//  Created by Nate Racklyeft on 9/28/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import UIKit

class MealTableViewCell: UITableViewCell {
    
    
    @IBOutlet weak var currentCarbLabel: UILabel!
    
    @IBOutlet weak var currentCarbDate: UILabel!
    
    @IBOutlet weak var undoLabel: UILabel!
    @IBOutlet weak var leftImageView: UIImageView!
    
    @IBOutlet weak var lastItemView: UIImageView!
    @IBOutlet weak var recentFoodCollectionView: UICollectionView! 
    
    @IBOutlet weak var debugLabelTop: UILabel!
    @IBOutlet weak var debugLabelBottom: UILabel!

    @objc func tapCell(_ sender: UITapGestureRecognizer) {
        if sender.state != .ended {
            return
        }
        let location = sender.location(in: self)
        let width = self.frame.width
                
        if location.y > 60 {
            return
        }
        if location.x < (self.frame.width - undoLabel.frame.width) {
            self.delegate?.mealTableViewCellTap(self)
        } else {
            self.delegate?.mealTableViewCellImageTap(self)

        }
    }
    
    var delegate: MealTableViewCellDelegate?
    override func awakeFromNib() {
        super.awakeFromNib()
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(tapCell(_:)))
        addGestureRecognizer(tapGesture)
        //tapGesture.delegate = ViewController()
        
    }
    
}

protocol MealTableViewCellDelegate {
    func mealTableViewCellImageTap(_ sender : MealTableViewCell)
    func mealTableViewCellTap(_ sender : MealTableViewCell)

}
