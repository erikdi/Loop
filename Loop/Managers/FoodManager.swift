//
//  FoodManager.swift
//  Loop
//
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import CarbKit

enum AbsorptionSpeed {
    case ultraFast  // like glucose tabs
    case fast       // like juice
    case normal
    case slow       // like pizza
    
    func encode() -> String {
        switch(self) {
        case .ultraFast: return "ultrafast"
        case .fast: return "fast"
        case .normal: return "normal"
        case .slow: return "slow"
        }
    }
}

extension AbsorptionSpeed {
    init?(raw: String) {
        switch(raw) {
        case "ultrafast":
            self = .ultraFast
        case "fast":
            self = .fast
        case "slow":
            self = .slow
        case "normal":
            self = .normal
        default:
            return nil
        }
    }
    
    var minutes : Double {
        let multiplier = LoopSettings().absorptionTimeMultiplier
        switch(self) {
        case .ultraFast:
                return round(multiplier * 90)
        case .fast:
                return round(multiplier * 120)
        case .normal:
                return round(multiplier * 180)
        case .slow:
                return round(multiplier * 300)
        }
    }
    var seconds : Double {
        return minutes * 60
    }
}

struct FoodItem {
    let carbRatio : Double    // 14g / 100g = 0.14
    let portionSize : Double  // 240g

    
    let absorption : AbsorptionSpeed
    let title : String
    
    var quantity : HKQuantity {
        return HKQuantity(unit: HKUnit.gram(), doubleValue: Double(carbPortion))
    }
    
    var carbPortion : Double {
        return portionSize * carbRatio
    }
}

extension FoodItem {
    init?(rawValues : [String: Any]) {
        carbRatio = rawValues["carbRatio"] as? Double ?? 0
        portionSize = rawValues["portionSize"] as? Double ?? 0
        title = rawValues["title"] as? String ?? ""
        absorption = rawValues["absorption"] as? AbsorptionSpeed ?? .normal
    }
    
    public func encode() -> [String: Any] {
            return [
            "carbRatio": carbRatio,
            "portionSize": portionSize,
            "title": title,
            "absorption": absorption.encode()
            ]

    }
}

struct FoodPick : CustomStringConvertible {
    let item : FoodItem
    let ratio : Double
    let date : Date
    let imageIdentifier : String?
    
    // Internally generated
    var quantity : HKQuantity {
        return HKQuantity(unit: HKUnit.gram(), doubleValue: carbs)
    }
    
    var carbEntry : CarbEntry {
        let representation : [Any] = [self.encode()]
        var foodType = item.title
        do {
            let data = try JSONSerialization.data(withJSONObject: representation, options: [])
            if let encodedData = String(data: data, encoding: .utf8) {
                foodType = encodedData
            }
        } catch {
            // TODO(Erik)
        }
        return NewCarbEntry(quantity: quantity, startDate: date, foodType: foodType,
                            absorptionTime: item.absorption.seconds)
    }
    
    var carbs : Double {
        return item.carbPortion * ratio
    }
    
    var displayPortion : String {
        let intPortion = Int(round(item.portionSize * ratio))
        return "\(intPortion)"
    }
    
    var displayCarbs : String {
        let intCarbs = Int(round(carbs))
        return "\(intCarbs)"
    }
    
    var description : String {
        let cr = Int(item.carbRatio * 100)
        return "\(displayPortion)g \(item.title): \(displayCarbs)g KH (\(cr)%)"
    }
    
    init(item : FoodItem, ratio: Double, date : Date) {
        self.init(item: item, ratio: ratio, date: date, imageIdentifier: nil)
    }
    
    init(item : FoodItem, ratio: Double, date : Date, imageIdentifier: String?) {
        self.item = item
        self.ratio = ratio
        self.date = date
        self.imageIdentifier = imageIdentifier
    }

}

extension FoodPick {
    init(rawValues : [String: Any]) {
        let it = FoodItem(rawValues: rawValues["item"] as! [String : Any])
        let rat = rawValues["ratio"] as? Double ?? 1.0
        let dat = Date(timeIntervalSince1970: rawValues["date"] as? Double ?? 0)
        let image = rawValues["image"] as? String
        self.init(item: it!, ratio: rat, date: dat, imageIdentifier: image)
    }
    
    func encode() -> [String: Any] {
        var ret : [String:Any] = [
            "item": item.encode(),
            "ratio": ratio,
            "date": date.timeIntervalSince1970
        ]
        if let image = imageIdentifier {
            ret["image"] = image
        }
        return ret
    }
    

    
}

struct FoodPicks {
    var picks : [FoodPick] = []
    
    var last : FoodPick? {
        return picks.last
    }
    
    var carbs : Double {
        var sum : Double = 0
        for pick in picks {
            sum += pick.carbs
        }
        return sum
    }
    
    mutating func append(_ pick : FoodPick) {
        picks.append(pick)
    }
    
    mutating func removeLast() -> FoodPick? {
        if picks.count > 0 {
            return picks.removeLast()
        }
        return nil
    }
    
    func toJSON() -> String? {
        var representation : [Any] = []
        for pick in picks {
            representation.append(pick.encode())
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: representation, options: [])
            
            return String(data: data, encoding: .utf8)
        } catch let error {
            NSLog("FoodPicks JSON representation error \(error)")
            return nil
        }
    }
    
    init() {
        self.picks = []
    }
    
    init(fromJSON: String) {
        do {
            let json = try JSONSerialization.jsonObject(with: fromJSON.data(using: .utf8)!, options: JSONSerialization.ReadingOptions())
            for rawValue in json as! [Any] {
                picks.append(FoodPick(rawValues: rawValue as! [String : Any]))
            }
        } catch let error {
            NSLog("FoodPicks fromJSON error \(error)")
        }

    }
}

struct FoodMetadata {
    enum FoodType {
        case continuous
        case single
        case multiple
        case drink
    }
    let type : FoodType
    let subtitle : String?
    let image : String?
    let initial : Double
    
    init(_ raw: [String: Any]) {
        switch raw["type"] as? String ?? "single" {
        case "continuous": type = .continuous
        case "single": type = .single
        case "multiple": type = .multiple
        case "drink": type = .drink
        default: type = .single
        }
        subtitle = raw["subtitle"] as? String
        image = raw["image"] as? String
        initial = raw["initial"] as? Double ?? 1  // in case of single or multiple servings
    }
}

final class FoodManager {
    
    public var items : [FoodItem] = []
    public var categories : [String: [FoodItem]] = ["Popular": []]
    public var sections : [String] = []
    private var itemByTitle : [String: FoodItem] = [:]
    private var meta : [String: FoodMetadata] = [:]
    func metaData(_ item: FoodItem) -> FoodMetadata {
        return meta[item.title] ?? FoodMetadata([:])
    }
    
    public var stats : [String:[String:Int]] = [:]
    
    func record(_ pick: FoodPick) {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: pick.date)
        let weekday = calendar.component(.weekday, from: pick.date)
        let key = "\(weekday)-\(hour)"
        let name = pick.item.title.lowercased()
        if var hourly = stats[key] {
            if let byname = hourly[name] {
                stats[key]![name] = byname + 1
            } else {
                stats[key]![name] = 1
            }
        } else {
            stats[key] = [name: 1]
        }
        NSLog("FoodManager record stats \(stats)")
        UserDefaults.standard.foodStats = stats
    }
    
    let popKey = "Popular"
    
    func updatePopular() {
        let calendar = Calendar.current
        let date = Date()
        let originalHour = calendar.component(.hour, from: date)
        let originalWeekday = calendar.component(.weekday, from: date)
        
        var list : [(Int, FoodItem)] = []
        var seen : [String] = []
        let varyHour = [0, -1, 1, -2, 2]
        let varyWeekday = [0, -1, 1, -2, 2, -3, 3]
        for w in varyWeekday {
            for h in varyHour {
                let hour = (originalHour + h) % 24
                let weekday = (originalWeekday + w) % 7
            
                let key = "\(weekday)-\(hour)"
                for entry in stats[key] ?? [:] {
                    if let item = itemByTitle[entry.key], !seen.contains(entry.key), entry.value > 1 {
                        list.append((entry.value, item))
                        seen.append(entry.key)
                    }
                }
            }
            if list.count > 8 { break }
        }
        list.sort { $0.0 > $1.0 }
        var newList : [FoodItem] = []
        for (_, item) in list {
            newList.append(item)
            if newList.count > 4 { break }
        }
        NSLog("FoodManager updatePopular \(newList)")
        categories[popKey] = newList
    }
    
    private func getDirectoryPath(_ fileName: String) -> String {
        let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        let documentsDirectory = paths[0] as NSString
        return documentsDirectory.appendingPathComponent(fileName)
    }
    
    func getCustomImage(_ fileName : String) -> UIImage? {
        let fileManager = FileManager.default
        let imagePath = getDirectoryPath(fileName)
        if fileManager.fileExists(atPath: imagePath) {
            return UIImage(contentsOfFile: imagePath)
        }
        return nil
    }
    
    func saveCustomImage(_ image: UIImage) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd hh:mm:ss"
        
        let fileName = dateFormatter.string(from: Date()) + ".jpg"

        let fileManager = FileManager.default
        let pathName = getDirectoryPath(fileName)
        let imageData = UIImageJPEGRepresentation(image, 85)
        fileManager.createFile(atPath: pathName as String, contents: imageData, attributes: nil)
        
        UserDefaults.standard.foodManagerNeedUpload.append(fileName)
        NSLog("FoodManager Upload Backlog \(UserDefaults.standard.foodManagerNeedUpload)")
        return fileName
    }
    
    func image(item: FoodItem) -> UIImage? {
        let meta = metaData(item)
        if let image = meta.image {
            return UIImage(named: "FoodCatalog/\(image).jpg")
        }
        return UIImage(named: "FoodCatalog/\(item.title).jpg")
    }
    
    func image(pick: FoodPick) -> UIImage? {
        if let imageIdentifier = pick.imageIdentifier {
            return getCustomImage(imageIdentifier)
        }
        return image(item: pick.item)
    }
    
    init() {
        do {

        guard let url = Bundle.main.url(forResource: "FoodCatalog/catalog", withExtension: "json") else {
            NSLog("FoodCatalog Cannot find catalog file")
            return
        }
        //let jsonData = try NSData(contentsOfFile: path, options: .mappedIfSafe)
        let jsonData = try Data(contentsOf: url)
            
        guard let json = try JSONSerialization.jsonObject(with: jsonData, options: JSONSerialization.ReadingOptions()) as? [String:Any] else {
            NSLog("FoodCatalog Cannot read json file at url \(url)")
            return
        }
            
        for raw in json {
            guard let value = raw.value as? [String: Any] else {
                NSLog("FoodManager ignoring malformed entry \(raw)")
                continue
            }
               // picks.append(FoodPick(rawValues: rawValue as! [String : Any]))
            if let carbspercent = value["ratio"] as? Double,
                let portionSize = value["portion"] as? Double {
                let title = value["title"] as? String ?? raw.key
                let absorptionString = value["absorption"] as? String ?? "normal"
                
                let absorption = AbsorptionSpeed(raw: absorptionString) ?? .normal

                let item = FoodItem(carbRatio: carbspercent / 100, portionSize: portionSize, absorption: absorption, title: title)
                items.append(item)
                if let s = value["categories"] as? [String] {
                    for section in s  {
                        if categories[section] != nil {
                            categories[section]!.append(item)
                        } else {
                            categories[section] = [item]
                        }
                    }
                }
                meta[item.title] = FoodMetadata(value)
                itemByTitle[item.title.lowercased()] = item
            } else {
                NSLog("FoodManager ignoring malformed entry \(raw)")
            }
        }
            NSLog("FoFoodManager Categories \(categories)")

        } catch let error {
            NSLog("FoodManager FoodCatalog Read Error \(error)")
        }
        sections = categories.keys.sorted()
        if let pop = sections.index(of: popKey) {
            sections.remove(at: pop)
        }
        sections.insert(popKey, at: 0)
        stats = UserDefaults.standard.foodStats
        NSLog("FoodManager stats loaded: \(stats)")
    }


}
