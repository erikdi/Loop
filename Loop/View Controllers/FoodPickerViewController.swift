//
//  FoodPickerViewController.swift
//  Loop
//
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopCore
import UIKit

final class FoodPickerFlowLayout: UICollectionViewFlowLayout {

    override init() {
        super.init()
        setupLayout()
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setupLayout()
    }
    
    func setupLayout() {
        minimumInteritemSpacing = 1
        minimumLineSpacing = 1
        scrollDirection = .vertical
        headerReferenceSize = CGSize(width: 0, height: 40)
    }

    override var itemSize: CGSize {
        set {
            
        }
        get {
            let numberOfColumns: CGFloat = 3
            
            let itemWidth = (self.collectionView!.frame.width - (numberOfColumns - 1)) / numberOfColumns
            return CGSize(width: itemWidth, height: itemWidth)
        }
    }
}

final class NewFoodPickerCollectionView : UICollectionView {

}

final class NewFoodPickerViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, IdentifiableClass {
    
    @IBOutlet weak var collectionView: UICollectionView!
    @IBOutlet weak var foodInfo: UILabel!
    @IBOutlet weak var sliderMultiplier: UISlider!
    @IBOutlet weak var selectionMultiplier: UISegmentedControl!
    @IBOutlet weak var sliderInfo: UILabel!
    
    var foodManager : FoodManager? = nil
    private var selected : IndexPath? = nil
    private var ratio : Double = 0
    
    private var previewImage : UIImage? = nil
    private var previewFileName : String? = nil
    
    var foodPick : FoodPick? = nil
    @IBOutlet weak var saveButtonItem: UIBarButtonItem!
    
    @IBAction func saveButton(_ sender: Any) {
        if let selected = self.selected, let item = foodItemForPath(selected) {
            var imageIdentifier : String? = nil
            if item.title == "Photo" {
                imageIdentifier = previewFileName
            }
            NSLog("NewFoodPickerViewController saveButtone image \(imageIdentifier as Any)")
            let pick = FoodPick(item: item, ratio: ratio, date: Date(), imageIdentifier: imageIdentifier)
            foodPick = pick
            foodManager?.record(pick)
            previewImage = nil
            previewFileName = nil
            AnalyticsManager.shared.didAddCarbsFromFoodPicker(pick)
            self.performSegue(withIdentifier: "close", sender: nil)
        }
    }
    
    
    @IBAction func unwindToFoodPicker(sender: UIStoryboardSegue)
    {
        guard let source = sender.source as? FoodPickerCameraViewController else {
            return
        }
        NSLog("unwindToFoodPicker we are back!")

        previewImage = source.imageOutput
        selected = source.selectedPath

        if let image = previewImage, let foodManager = foodManager {
            previewFileName = foodManager.saveCustomImage(image)
        }
        
        NSLog("unwindToFoodPicker filename \(String(describing: previewFileName)) selected \(String(describing: selected))")
        
        if let indexPath = selected {
            saveButtonItem.isEnabled = true
            
            updateTopControls(indexPath: indexPath)
            collectionView.reloadItems(at: [indexPath])

        }

    }
    
    
    func foodItemForPath(_ indexPath : IndexPath) -> FoodItem? {
        if let foodManager = foodManager {
            let sectionName = foodManager.sections[indexPath.section]
            let category = foodManager.categories[sectionName]
            return category?[indexPath.item]
            //return foodManager.items[indexPath.item]
        }
        return nil
    }
    
    override func viewWillAppear(_ animated: Bool) {
        foodPick = nil
        /*
        previewImage = nil
        previewFileName = nil
        */
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.collectionViewLayout = FoodPickerFlowLayout()

        updateTopControls(indexPath: selected)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        AnalyticsManager.shared.didDisplayFoodPicker()
    }
    
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "foodImageCell" , for: indexPath) as! FoodCollectionViewCell
        
        
        if let item = foodItemForPath(indexPath) {
            cell.imageView.layer.masksToBounds = true
            cell.imageView.clipsToBounds = true
            if item.title == "Photo", previewImage != nil {
                cell.imageView.image = previewImage
            } else {
                cell.imageView.image = foodManager?.image(item: item)
            }
            if cell.imageView.image == nil {
                let carbs = Int(round(item.carbPortion))
                cell.carbLabel?.text = "\(carbs)"
            } else {
                cell.carbLabel?.text = ""
            }
            
            cell.foodLabel?.text = "\(item.title)"

            if self.selected == indexPath {
                cell.backgroundColor = UIColor(red: 0.278, green: 0.694, blue: 0.537, alpha: 1.00)
                
                // cell.contentView.backgroundColor =  UIColor(colorLiteralRed: 0.278, green: 0.694, blue: 0.537, alpha: 1.00)
            } else {
                cell.backgroundColor = UIColor.white
                
            }
        }
        return cell
    }
    
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        guard let foodManager = foodManager else { return 0; }
        return foodManager.sections.count
    }
    
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        guard let foodManager = foodManager else { return 0; }
        let sectionName = foodManager.sections[section]
        let category = foodManager.categories[sectionName]
        return category!.count
    }
    
    func updateTopControls(indexPath: IndexPath?) {
        guard let indexPath = indexPath else {
            sliderMultiplier.isEnabled = false
            sliderMultiplier.isHidden = true
            selectionMultiplier.isHidden = true
            foodInfo.text = "Select food!"
            sliderInfo.text = ""
            saveButtonItem.isEnabled = false
            return
        }
        if let foodManager = self.foodManager, let item = foodItemForPath(indexPath) {
            
            let meta = foodManager.metaData(item)
            saveButtonItem.isEnabled = true

            if let slider = sliderMultiplier, let selector = selectionMultiplier {
                slider.isEnabled = true
                switch meta.type {
                case .continuous:
                    slider.minimumValue = Float(item.portionSize / 4)
                    slider.maximumValue = Float(item.portionSize * 2)
                    slider.setValue(Float(item.portionSize), animated: false)
                    slider.isHidden = false
                    selector.isHidden = true
                case .drink:
                    slider.minimumValue = Float(item.portionSize / 4)
                    slider.maximumValue = max(Float(item.portionSize * 2), 500)
                    slider.setValue(Float(item.portionSize), animated: false)
                    slider.isHidden = false
                    selector.isHidden = true
                case .multiple:
                    slider.minimumValue = 1
                    slider.maximumValue = 8
                    slider.setValue(Float(meta.initial), animated: false)
                    slider.isHidden = false
                    selector.isHidden = true
                    
                case .single:
                    selector.selectedSegmentIndex = 2
                    slider.isHidden = true
                    selector.isHidden = false
                    
                }
                sliderValueChanged(slider)
            }
        }
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        super.prepare(for: segue, sender: sender)
        
        var targetViewController = segue.destination
        if let navVC = targetViewController as? UINavigationController, let topViewController = navVC.topViewController {
            targetViewController = topViewController
        }
        switch targetViewController {
        case let vc as FoodPickerCameraViewController:
            vc.selectedPath = selected
        default:
            break
        }
    }
        
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {        
        var reloadPath = [indexPath]
        if let selected = self.selected {
            reloadPath.append(selected)
        }
        self.selected = indexPath
        if let item = foodItemForPath(indexPath) {
            if item.title == "Photo" {
                performSegue(withIdentifier: FoodPickerCameraViewController.className, sender: self)
                return
            }
        }
        updateTopControls(indexPath: indexPath)

        collectionView.reloadItems(at: reloadPath)
    }
    
    @IBAction func selectionValueChanged(_ sender: Any) {
        sliderValueChanged(self.sliderMultiplier)
    }
    
    
    @IBAction func sliderMultiplierValueChanged(_ sender: Any) {
        sliderValueChanged(self.sliderMultiplier)
    }
    
    func sliderValueChanged(_ sender : UISlider) {
        guard let foodManager = self.foodManager else { return }
        guard let selected = self.selected else { return }
        guard let item = foodItemForPath(selected) else { return }
        
        let meta = foodManager.metaData(item)
        
        let selector = selectionMultiplier
        
        var value = sender.value
        var total = 0.0
        var unit = "g"
        switch meta.type {
            
        case .single:
            switch(selector?.selectedSegmentIndex ?? 2) {
            case 0: value = 0.5
            case 1: value = 0.7
            case 2: value = 1
            case 3: value = 1.5
            default: value = 1
            }
            
            sliderInfo.text = ""
            total = item.portionSize * Double(value)
            ratio = Double(value)
            
        case .multiple:
            value = round(value)
            let intvalue = Int(value)
            sliderInfo.text = "\(intvalue)x"
            total = item.portionSize * Double(value)
            ratio = Double(value)
            
        case .continuous:
            value = round(value / 10) * 10
            let intvalue = Int(value)
            sliderInfo.text = "\(intvalue)g"
            total = Double(value)
            ratio = total / item.portionSize
            
        case .drink:
            value = round(value / 50) * 50
            let intvalue = Int(value)
            sliderInfo.text = "\(intvalue)ml"
            total = Double(value)
            ratio = total / item.portionSize
            unit = "ml"
        }
        sender.setValue(value, animated: false)
        
        let cr = Int(round(item.carbRatio * 100))
        
        let ps = Int(round(total))
        let cp = Int(round(total * item.carbRatio))
        
        let title = meta.subtitle ?? item.title
        foodInfo.text = "\(title): \(ps) \(unit), Carbs \(cp) g (\(cr)%)"
    }
    
    
    func collectionView(_ collectionView: UICollectionView,
                                 viewForSupplementaryElementOfKind kind: String,
                                 at indexPath: IndexPath) -> UICollectionReusableView {
        switch kind {
        case UICollectionView.elementKindSectionHeader:
            //3
            let view = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "FoodCollectionReusableView", for: indexPath) as! FoodCollectionReusableView
            let sectionName = foodManager?.sections[indexPath.section]
            view.headerLabel.text = sectionName ?? "Undefined"
            return view
        default:
            assert(false, "Unexpected element kind")
        }
        return UICollectionReusableView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    
    
}
