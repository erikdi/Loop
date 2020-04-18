import UIKit

final class FoodRecentPickerFlowLayout: UICollectionViewFlowLayout {
    
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
        scrollDirection = .horizontal
    }
    
    override var itemSize: CGSize {
        set {
            
        }
        get {
            let itemHeight = self.collectionView!.frame.height
            return CGSize(width: itemHeight, height: itemHeight)
        }
    }
}

class FoodRecentCollectionViewDataSource : NSObject, UICollectionViewDataSource {
    
    
    var foodPicks : FoodPicks = FoodPicks()
    var foodManager : FoodManager? = nil
    
    
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        return 1
    }
    
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "foodRecentImageCell" , for: indexPath) as! FoodCollectionViewCell

        let items = foodPicks.picks
        let pick = items[indexPath.item]
        cell.imageView.layer.masksToBounds = true
        cell.imageView.clipsToBounds = true
        cell.imageView.image = foodManager?.image(pick: pick)
        if cell.imageView.image == nil && pick.item.title.count == 1 {
            cell.emojiLabel?.text = pick.item.title
        } else {
            cell.emojiLabel?.text = ""
        }
        let carbs = Int(round(pick.carbs))
        cell.carbLabel?.text = "\(carbs)"
        return cell
    }
    
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {

        return foodPicks.picks.count
    }

    
}
