import UIKit
import AVFoundation
import LoopCore

class FoodPickerCameraViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate, IdentifiableClass {
    
    var previewLayer : AVCaptureVideoPreviewLayer?
    @IBOutlet weak var previewView: UIView!
    
    // If we find a device we'll store it here for later use
    private var captureDevice : AVCaptureDevice?
    private let captureSession = AVCaptureSession()
    private var output = AVCapturePhotoOutput()
    private var videoOutput = AVCaptureVideoDataOutput()
    private var videoDataOutputQueue = DispatchQueue.init(label: "VideoDataOutputQueue")
    private var captureQueue = DispatchQueue.init(label: "PhotoCaptureSessionQueue")


    var selectedPath : IndexPath?
    var imageOutput : UIImage?

    override func viewDidLoad() {
        super.viewDidLoad()
        

        let cameraPermissionStatus =  AVCaptureDevice.authorizationStatus(for: AVMediaType.video)
        
        switch cameraPermissionStatus {
        case .authorized:
            NSLog("Already Authorized")
        case .denied:
            NSLog("denied")
        case .restricted:
            NSLog("restricted")
        default:
            AVCaptureDevice.requestAccess(for: AVMediaType.video, completionHandler: {
               // [weak self]
                (granted :Bool) -> Void in
                NSLog("granted", granted)
            });
        }
        
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [AVCaptureDevice.DeviceType.builtInWideAngleCamera], mediaType: AVMediaType.video, position: AVCaptureDevice.Position.back)
        // Loop through all the capture devices on this phone
        captureDevice = session.devices.first
        NSLog("captureDevice \(String(describing: captureDevice)) \(session.devices)")
        captureQueue.async {
            NSLog("async beginSession")
            self.beginSession()
        }
    }
    
    
    @IBAction func captureButton(_ sender: Any) {
        capturePhoto()
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        capturePhoto()
    }
    
    func configureDevice() {
        if let device = captureDevice {
            do {
                try device.lockForConfiguration()
                //device.focusMode = .locked
                //device.automaticallyEnablesLowLightBoostWhenAvailable = true
                //device.automaticallyAdjustsVideoHDREnabled = true
                
                device.unlockForConfiguration()
            } catch let error {
                NSLog("lockForConfiguration Failed \(error)")
            }
        }
        
    }
    
    func imageFromSampleBuffer(sampleBuffer : CMSampleBuffer) -> UIImage
    {
        // Get a CMSampleBuffer's Core Video image buffer for the media data
        let  imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        // Lock the base address of the pixel buffer
        CVPixelBufferLockBaseAddress(imageBuffer!, CVPixelBufferLockFlags.readOnly);
        
        
        // Get the number of bytes per row for the pixel buffer
        let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer!);
        
        // Get the number of bytes per row for the pixel buffer
        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer!);
        // Get the pixel buffer width and height
        let width = CVPixelBufferGetWidth(imageBuffer!);
        let height = CVPixelBufferGetHeight(imageBuffer!);
        
        // Create a device-dependent RGB color space
        let colorSpace = CGColorSpaceCreateDeviceRGB();
        
        // Create a bitmap graphics context with the sample buffer data
        var bitmapInfo: UInt32 = CGBitmapInfo.byteOrder32Little.rawValue
        bitmapInfo |= CGImageAlphaInfo.premultipliedFirst.rawValue & CGBitmapInfo.alphaInfoMask.rawValue
        //let bitmapInfo: UInt32 = CGBitmapInfo.alphaInfoMask.rawValue
        let context = CGContext.init(data: baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo)
        // Create a Quartz image from the pixel data in the bitmap graphics context
        let quartzImage = context?.makeImage();
        // Unlock the pixel buffer
        CVPixelBufferUnlockBaseAddress(imageBuffer!, CVPixelBufferLockFlags.readOnly);
        
        // Create an image object from the Quartz image
        let image = UIImage.init(cgImage: quartzImage!)
        
        return (image);
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        captureQueue.async {
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }
    
    private var captureVideoFrame = false
    func captureOutput(_ captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, from connection: AVCaptureConnection!) {
        if captureVideoFrame {
            captureVideoFrame = false
            let image = imageFromSampleBuffer(sampleBuffer: sampleBuffer)
            NSLog("capture sampleBuffer")
            imageOutput = image
            performSegue(withIdentifier: "close", sender: self)
        }
    }
    
    @objc func sessionRuntimeError(notification: NSNotification) {
        guard let errorValue = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError else {
            return
        }
        
        let error = AVError(_nsError: errorValue)
        NSLog("Capture session runtime error: \(error)")
    }
    
    func beginSession() {

        configureDevice()
        captureSession.beginConfiguration()
        // Do any additional setup after loading the view, typically from a nib.
        captureSession.sessionPreset = AVCaptureSession.Preset.photo

        do {
            if let device = captureDevice {
               try captureSession.addInput(AVCaptureDeviceInput(device: device))
            }
        } catch let error {
            NSLog("addInput Failed \(error)")
            captureSession.commitConfiguration()
            return
        }
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
        } else {
            NSLog("Cannot add Output")
            captureSession.commitConfiguration()
            return
        }
        
        videoOutput.alwaysDiscardsLateVideoFrames = true
        //videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey:Int(kCVPixelFormatType_32BGRA)]
        videoOutput.videoSettings = NSDictionary(object: NSNumber(value: kCVPixelFormatType_32BGRA), forKey: NSString(string: kCVPixelBufferPixelFormatTypeKey)) as! [String:Any]

        videoOutput.setSampleBufferDelegate(self, queue:self.videoDataOutputQueue)
        //captureSession.addOutput(videoOutput)

        captureSession.commitConfiguration()

        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
           // previewLayer.videoGravity = AVLayerVideoGravityResizeAspect
        previewLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
            self.previewView.layer.masksToBounds = true
            //previewLayer.frame = self.previewView.layer.frame
            DispatchQueue.main.async {
            //previewLayer.frame = self.previewView.bounds
                previewLayer.frame = CGRect(x: 0, y: 0, width: 500, height: 500)
                previewLayer.bounds = previewLayer.frame

                NSLog("preview layer frame \(previewLayer.frame), \(self.previewView.bounds), \(self.previewView.layer.frame)")
                self.previewView.layer.addSublayer(previewLayer)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError), name: .AVCaptureSessionRuntimeError, object: captureSession)

            captureSession.startRunning()
            if !captureSession.isRunning {
                NSLog("Cannot start capture session for some reason.")
            }
        
        
    }
    
    override func viewWillAppear(_ animated: Bool) {
        //code
    }
    
    func capturePhoto() {
        //captureVideoFrame = true
        if !captureSession.isRunning {
            return
        }
        let settings = AVCapturePhotoSettings()
        let previewPixelType = settings.availablePreviewPhotoPixelFormatTypes.first!
        let previewFormat = [kCVPixelBufferPixelFormatTypeKey as String: previewPixelType,
                             kCVPixelBufferWidthKey as String: 160,
                             kCVPixelBufferHeightKey as String: 160]
        settings.previewPhotoFormat = previewFormat
        output.capturePhoto(with: settings, delegate: self)
    }
    
    //MARK: - Add image to Library
    @objc func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        NSLog("Successfully saved image to camera roll")
    }
    
    func crop(image: UIImage, withWidth width: Double, andHeight height: Double) -> UIImage? {
        
        if let cgImage = image.cgImage {
            
            let contextImage: UIImage = UIImage(cgImage: cgImage)
            
            let contextSize: CGSize = contextImage.size
            
            var posX: CGFloat = 0.0
            var posY: CGFloat = 0.0
            var cgwidth: CGFloat = CGFloat(width)
            var cgheight: CGFloat = CGFloat(height)
            
            // See what size is longer and create the center off of that
            if contextSize.width > contextSize.height {
                posX = 0//((contextSize.width - contextSize.height) / 2)
                posY = 0
                cgwidth = contextSize.height
                cgheight = contextSize.height
            } else {
                posX = 0
                posY = 0// ((contextSize.height - contextSize.width) / 2)
                cgwidth = contextSize.width
                cgheight = contextSize.width
            }
            
            let rect: CGRect = CGRect(x: posX, y: posY, width: cgwidth, height: cgheight)
            
            // Create bitmap image from context using the rect
            var croppedContextImage: CGImage? = nil
            if let contextImage = contextImage.cgImage {
                if let croppedImage = contextImage.cropping(to: rect) {
                    croppedContextImage = croppedImage
                }
            }
            
            // Create a new image based on the imageRef and rotate back to the original orientation
            if let croppedImage:CGImage = croppedContextImage {
                let image: UIImage = UIImage(cgImage: croppedImage, scale: image.scale, orientation: image.imageOrientation)
                return image
            }
            
        }
        return nil
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error = error {
            NSLog("capture error \(error.localizedDescription)")
            return
        }
        
        if let data = photo.fileDataRepresentation() {
            if let image = UIImage(data: data) {
                saveImageCallback(image)
            }
        }
    }
    /*
    func photoOutput(_ captureOutput: AVCapturePhotoOutput, didFinishProcessingPhoto photoSampleBuffer: CMSampleBuffer?, previewPhoto previewPhotoSampleBuffer: CMSampleBuffer?, resolvedSettings: AVCaptureResolvedPhotoSettings, bracketSettings: AVCaptureBracketedStillImageSettings?, error: Error?) {
        
        if let error = error {
            NSLog("capture error \(error.localizedDescription)")
            return
        }
        
        if let sampleBuffer = photoSampleBuffer, let previewBuffer = previewPhotoSampleBuffer, let dataImage = AVCapturePhotoOutput.jpegPhotoDataRepresentation(forJPEGSampleBuffer: sampleBuffer, previewPhotoSampleBuffer: previewBuffer), let image = UIImage(data: dataImage) {
            
            saveImageCallback(image)
        }
    }
    */
    
    func saveImageCallback(_ image: UIImage) {
            NSLog("Image Size \(image.size)")
            let newWidth = 1024.0
            let newHeight = 1024.0
            let newSize = CGSize(width: newWidth, height: newHeight)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            
            let croppedImage : UIImage? = self.crop(image: image, withWidth: 1024, andHeight: 1024)
            
            let newImage = renderer.image{_ in
                croppedImage?.draw(in: CGRect.init(origin: CGPoint.zero, size: newSize))
            }
            
            // until we can upload the images, just save them to the camera roll.
            UIImageWriteToSavedPhotosAlbum(newImage, self, #selector(image(_:didFinishSavingWithError:contextInfo:)), nil)
            
            imageOutput = newImage
            
            performSegue(withIdentifier: "close", sender: self)
    }
    
}
