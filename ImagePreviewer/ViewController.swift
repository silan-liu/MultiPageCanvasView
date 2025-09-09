import UIKit
import PDFKit
import UIKit

// MARK: - CanvasView
class CanvasView: UIView {
    
    // MARK: - Properties
    
    // 内容视图（你要缩放和拖动的内容）
    private let contentView = UIView()
    
    // 变换相关属性
    private var currentScale: CGFloat = 1.0
    private var currentTranslation: CGPoint = .zero
    
    // 缩放限制
    var minimumZoomScale: CGFloat = 0.5 {
        didSet { enforceZoomLimits() }
    }
    var maximumZoomScale: CGFloat = 3.0 {
        didSet { enforceZoomLimits() }
    }
    
    // 配置选项
    var bouncesZoom: Bool = true
    var isScrollEnabled: Bool = true
    var isPinchEnabled: Bool = true
    
    // 手势相关
    private var lastPinchScale: CGFloat = 1.0
    private var lastPanTranslation: CGPoint = .zero
    private var isPinching: Bool = false
    
    // 内容边界（可选，用于限制拖动范围）
    var contentSize: CGSize = .zero
    var constrainContentToBounds: Bool = false
    
    // 代理
    weak var delegate: CanvasViewDelegate?
    
    // MARK: - Initialization
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }
    
    private func setupView() {
        // 设置基础属性
        backgroundColor = .systemBackground
        clipsToBounds = true
        
        // 添加内容视图
        addSubview(contentView)
        contentView.frame = bounds
        contentView.backgroundColor = .clear
      
      print("contentView frame:\(contentView.frame)")
        
        // 设置手势识别器
        setupGestures()
    }
    
    private func setupGestures() {
        // 拖动手势
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.delegate = self
        addGestureRecognizer(panGesture)
        
        // 缩放手势
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinchGesture.delegate = self
        addGestureRecognizer(pinchGesture)
        
        // 双击手势
        let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTapGesture.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTapGesture)
    }
    
    // MARK: - Content Management
    
    /// 添加内容到画布
    func setContent(_ view: UIView) {
        // 清除旧内容
        contentView.subviews.forEach { $0.removeFromSuperview() }
        
        // 添加新内容
        contentView.addSubview(view)
        
        // 设置内容大小
        if contentSize == .zero {
            contentSize = view.bounds.size
        }
        
        // 初始化位置
        resetTransform()
    }
    
    /// 添加图片内容
    func setImage(_ image: UIImage) {
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = CGRect(origin: .zero, size: image.size)
        
        contentSize = image.size
        setContent(imageView)
        
        // 自动适应屏幕
        fitToScreen(animated: false)
    }
    
    // MARK: - Gesture Handlers
    
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard isScrollEnabled else { return }
        
        let translation = gesture.translation(in: self)
        
        switch gesture.state {
        case .began:
            lastPanTranslation = translation
            delegate?.canvasViewWillBeginDragging?(self)
            
        case .changed:
            let deltaX = translation.x - lastPanTranslation.x
            let deltaY = translation.y - lastPanTranslation.y
            
            currentTranslation.x += deltaX
            currentTranslation.y += deltaY
            
            if constrainContentToBounds {
                constrainTranslation()
            }
            
            updateTransform()
            lastPanTranslation = translation
            
            delegate?.canvasViewDidScroll?(self)
            
        case .ended, .cancelled:
            // 添加惯性效果（可选）
            if constrainContentToBounds {
                animateToConstrainedPosition()
            }
            
            delegate?.canvasViewDidEndDragging?(self)
            
        default:
            break
        }
    }
    
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard isPinchEnabled else { return }
        
        switch gesture.state {
        case .began:
            isPinching = true
            lastPinchScale = gesture.scale
            delegate?.canvasViewWillBeginZooming?(self)
            
        case .changed:
            // 计算新的缩放值
            let deltaScale = gesture.scale / lastPinchScale
            var newScale = currentScale * deltaScale
            
            // 应用缩放限制
            if !bouncesZoom {
                newScale = min(max(newScale, minimumZoomScale), maximumZoomScale)
            } else {
                // 允许弹性，但有更大的限制
                let bounceMin = minimumZoomScale * 0.9
                let bounceMax = maximumZoomScale * 1.1
                newScale = min(max(newScale, bounceMin), bounceMax)
            }
            
            // 获取缩放中心点
            let pinchCenter = gesture.location(in: contentView)
            
            // 调整位置以保持缩放中心
            let scaleRatio = newScale / currentScale
            currentTranslation.x = currentTranslation.x * scaleRatio + (1 - scaleRatio) * pinchCenter.x
            currentTranslation.y = currentTranslation.y * scaleRatio + (1 - scaleRatio) * pinchCenter.y
            
            currentScale = newScale
            lastPinchScale = gesture.scale
            
            updateTransform()
            delegate?.canvasViewDidZoom?(self)
            
        case .ended, .cancelled:
            isPinching = false
            
            // 弹回到限制范围内
            animateToValidScale()
            delegate?.canvasViewDidEndZooming?(self, with: currentScale)
            
        default:
            break
        }
    }
    
    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        let tapLocation = gesture.location(in: contentView)
        
        if currentScale > minimumZoomScale * 1.1 {
            // 缩小到最小
            animateToScale(minimumZoomScale, center: tapLocation)
        } else {
            // 放大到2倍或中间值
            let targetScale = min(minimumZoomScale * 2.5, maximumZoomScale)
            animateToScale(targetScale, center: tapLocation)
        }
    }
    
    // MARK: - Transform Updates
    
    private func updateTransform() {
        // 应用缩放和平移变换
        let transform = CGAffineTransform.identity
            .scaledBy(x: currentScale, y: currentScale)
            .translatedBy(x: currentTranslation.x / currentScale, y: currentTranslation.y / currentScale)
        
        contentView.transform = transform
    }
    
    private func enforceZoomLimits() {
        if currentScale < minimumZoomScale {
            currentScale = minimumZoomScale
            updateTransform()
        } else if currentScale > maximumZoomScale {
            currentScale = maximumZoomScale
            updateTransform()
        }
    }
    
    // MARK: - Constraints
    
    private func constrainTranslation() {
        guard constrainContentToBounds else { return }
        
        let scaledContentSize = CGSize(
            width: contentSize.width * currentScale,
            height: contentSize.height * currentScale
        )
        
        let boundSize = bounds.size
        
        // 计算最大和最小平移值
        let minX = min(0, boundSize.width - scaledContentSize.width)
        let maxX = max(0, boundSize.width - scaledContentSize.width)
        let minY = min(0, boundSize.height - scaledContentSize.height)
        let maxY = max(0, boundSize.height - scaledContentSize.height)
        
        currentTranslation.x = min(max(currentTranslation.x, minX), maxX)
        currentTranslation.y = min(max(currentTranslation.y, minY), maxY)
    }
    
    // MARK: - Animations
    
    private func animateToScale(_ scale: CGFloat, center: CGPoint) {
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut]) {
            // 计算新的平移以保持中心点
            let scaleRatio = scale / self.currentScale
            self.currentTranslation.x = self.currentTranslation.x * scaleRatio + (1 - scaleRatio) * center.x
            self.currentTranslation.y = self.currentTranslation.y * scaleRatio + (1 - scaleRatio) * center.y
            
            self.currentScale = scale
            
            if self.constrainContentToBounds {
                self.constrainTranslation()
            }
            
            self.updateTransform()
        }
    }
    
    private func animateToValidScale() {
        var targetScale = currentScale
        
        if currentScale < minimumZoomScale {
            targetScale = minimumZoomScale
        } else if currentScale > maximumZoomScale {
            targetScale = maximumZoomScale
        } else {
            return // 已经在有效范围内
        }
        
        UIView.animate(withDuration: 0.2) {
            self.currentScale = targetScale
            self.updateTransform()
        }
    }
    
    private func animateToConstrainedPosition() {
        let oldTranslation = currentTranslation
        constrainTranslation()
        
        if currentTranslation != oldTranslation {
            UIView.animate(withDuration: 0.2) {
                self.updateTransform()
            }
        }
    }
    
    // MARK: - Public Methods
    
    /// 重置变换到初始状态
    func resetTransform() {
        currentScale = 1.0
        currentTranslation = .zero
        updateTransform()
    }
    
    /// 适应屏幕显示
    func fitToScreen(animated: Bool = true) {
        guard contentSize != .zero else { return }
        
        let scaleX = bounds.width / contentSize.width
        let scaleY = bounds.height / contentSize.height
        let scale = min(scaleX, scaleY)
        
        // 居中内容
        let scaledSize = CGSize(
            width: contentSize.width * scale,
            height: contentSize.height * scale
        )
        
        let centerX = (bounds.width - scaledSize.width) / 2
        let centerY = (bounds.height - scaledSize.height) / 2
        
        if animated {
            UIView.animate(withDuration: 0.3) {
                self.currentScale = scale
                self.currentTranslation = CGPoint(x: centerX, y: centerY)
                self.updateTransform()
            }
        } else {
            currentScale = scale
            currentTranslation = CGPoint(x: centerX, y: centerY)
            updateTransform()
        }
    }
    
    /// 填满屏幕显示
    func fillScreen(animated: Bool = true) {
        guard contentSize != .zero else { return }
        
        let scaleX = bounds.width / contentSize.width
        let scaleY = bounds.height / contentSize.height
        let scale = max(scaleX, scaleY)
        
        if animated {
            UIView.animate(withDuration: 0.3) {
                self.currentScale = scale
                self.currentTranslation = .zero
                self.updateTransform()
            }
        } else {
            currentScale = scale
            currentTranslation = .zero
            updateTransform()
        }
    }
    
    /// 设置缩放比例
    func setZoomScale(_ scale: CGFloat, animated: Bool = true) {
        let validScale = min(max(scale, minimumZoomScale), maximumZoomScale)
        
        if animated {
            UIView.animate(withDuration: 0.3) {
                self.currentScale = validScale
                self.updateTransform()
            }
        } else {
            currentScale = validScale
            updateTransform()
        }
    }
    
    /// 获取当前缩放比例
    var zoomScale: CGFloat {
        return currentScale
    }
    
    /// 获取当前偏移
    var contentOffset: CGPoint {
        return CGPoint(x: -currentTranslation.x, y: -currentTranslation.y)
    }
}

// MARK: - UIGestureRecognizerDelegate
extension CanvasView: UIGestureRecognizerDelegate {
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                          shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // 允许同时识别拖动和缩放
        return true
    }
}

// MARK: - CanvasViewDelegate
@objc protocol CanvasViewDelegate: AnyObject {
    @objc optional func canvasViewWillBeginDragging(_ canvasView: CanvasView)
    @objc optional func canvasViewDidScroll(_ canvasView: CanvasView)
    @objc optional func canvasViewDidEndDragging(_ canvasView: CanvasView)
    
    @objc optional func canvasViewWillBeginZooming(_ canvasView: CanvasView)
    @objc optional func canvasViewDidZoom(_ canvasView: CanvasView)
    @objc optional func canvasViewDidEndZooming(_ canvasView: CanvasView, with scale: CGFloat)
}

// MARK: - 使用示例
class CanvasViewController: UIViewController {
    
  private let canvasView = CanvasView(frame: CGRectMake(0, 0, 393, 852))
    
    override func viewDidLoad() {
        super.viewDidLoad()
      
      print(self.view.bounds)
        
        setupCanvas()
        loadContent()
    }
    
    private func setupCanvas() {
        view.backgroundColor = .systemBackground
        
        // 添加画布
        view.addSubview(canvasView)
    
//        canvasView.translatesAutoresizingMaskIntoConstraints = false
//        NSLayoutConstraint.activate([
//            canvasView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
//            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
//            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
//            canvasView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
//        ])
        
        // 配置画布
        canvasView.minimumZoomScale = 0.5
        canvasView.maximumZoomScale = 5.0
        canvasView.bouncesZoom = true
        canvasView.constrainContentToBounds = true
        canvasView.delegate = self
    }
    
    private func loadContent() {
        // 示例1：加载图片
        if let image = UIImage(named: "test") {
            canvasView.setImage(image)
        }
        
        // 示例2：加载自定义视图
        // let customView = createCustomContent()
        // canvasView.setContent(customView)
    }
    
    private func createCustomContent() -> UIView {
        // 创建一个示例内容视图
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 800, height: 1200))
        container.backgroundColor = .systemGray6
        
        // 添加一些子视图作为示例
        let label = UILabel(frame: CGRect(x: 100, y: 100, width: 600, height: 50))
        label.text = "Canvas Content"
        label.font = .systemFont(ofSize: 36, weight: .bold)
        label.textAlignment = .center
        container.addSubview(label)
        
        // 添加一些形状
        let circleView = UIView(frame: CGRect(x: 200, y: 300, width: 400, height: 400))
        circleView.backgroundColor = .systemBlue
        circleView.layer.cornerRadius = 200
        container.addSubview(circleView)
        
        return container
    }
}

// MARK: - CanvasViewDelegate Implementation
extension CanvasViewController: CanvasViewDelegate {
    
    func canvasViewDidZoom(_ canvasView: CanvasView) {
        print("Current zoom scale: \(canvasView.zoomScale)")
    }
    
    func canvasViewDidEndZooming(_ canvasView: CanvasView, with scale: CGFloat) {
        print("Zoom ended at scale: \(scale)")
    }
}

// MARK: - 高级使用示例
/*
// 1. 创建绘图画布
class DrawingCanvasView: CanvasView {
    private var drawingLayer = CAShapeLayer()
    private var currentPath = UIBezierPath()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupDrawingLayer()
    }
    
    private func setupDrawingLayer() {
        drawingLayer.strokeColor = UIColor.black.cgColor
        drawingLayer.lineWidth = 2.0
        drawingLayer.fillColor = nil
        layer.addSublayer(drawingLayer)
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let location = touch.location(in: self)
        currentPath.move(to: location)
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let location = touch.location(in: self)
        currentPath.addLine(to: location)
        drawingLayer.path = currentPath.cgPath
    }
}

// 2. 无限画布
class InfiniteCanvasView: CanvasView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        constrainContentToBounds = false  // 允许无限滚动
        contentSize = CGSize(width: 10000, height: 10000)  // 大画布
    }
}

// 3. 带网格的画布
class GridCanvasView: CanvasView {
    private func addGridBackground() {
        let gridSize: CGFloat = 50
        let gridLayer = CAShapeLayer()
        let path = UIBezierPath()
        
        // 绘制网格线
        for i in 0...Int(contentSize.width / gridSize) {
            let x = CGFloat(i) * gridSize
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: contentSize.height))
        }
        
        for i in 0...Int(contentSize.height / gridSize) {
            let y = CGFloat(i) * gridSize
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: contentSize.width, y: y))
        }
        
        gridLayer.path = path.cgPath
        gridLayer.strokeColor = UIColor.lightGray.cgColor
        gridLayer.lineWidth = 0.5
        contentView.layer.insertSublayer(gridLayer, at: 0)
    }
}
*/
