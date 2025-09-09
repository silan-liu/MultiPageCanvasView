import UIKit
import PDFKit

// MARK: - PDF数据源协议
protocol PDFDataSource {
    func numberOfPages() -> Int
    func pageAt(index: Int) -> PDFPage?
    func documentTitle() -> String?
}

// MARK: - 默认PDF数据源实现
class DefaultPDFDataSource: PDFDataSource {
    private let pdfDocument: PDFDocument
    
    init(pdfDocument: PDFDocument) {
        self.pdfDocument = pdfDocument
    }
    
    func numberOfPages() -> Int {
        return pdfDocument.pageCount
    }
    
    func pageAt(index: Int) -> PDFPage? {
        return pdfDocument.page(at: index)
    }
    
    func documentTitle() -> String? {
        return pdfDocument.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
    }
}

// MARK: - PDF页面缓存管理
class PDFPageCache {
    static let shared = PDFPageCache()
    
    private let cache = NSCache<NSString, UIImage>()
    private let renderQueue = DispatchQueue(label: "pdf.render.queue", qos: .userInitiated)
    private var renderTasks: [String: DispatchWorkItem] = [:]
   private let tasksQueue = DispatchQueue(label: "pdf.tasks.queue", attributes: .concurrent)

    private init() {
        // 设置缓存限制
        cache.totalCostLimit = 200 * 1024 * 1024 // 200MB
        cache.countLimit = 50 // 最多缓存50页
        
        // 监听内存警告
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didReceiveMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }
    
    @objc private func didReceiveMemoryWarning() {
        cache.removeAllObjects()
        renderTasks.values.forEach { $0.cancel() }
        renderTasks.removeAll()
    }
    
    func renderPage(_ page: PDFPage, at size: CGSize, scale: CGFloat, completion: @escaping (UIImage?) -> Void) {
        let cacheKey = cacheKeyFor(page: page, size: size, scale: scale)
        
        // 检查缓存
        if let cachedImage = cache.object(forKey: cacheKey as NSString) {
            completion(cachedImage)
            return
        }
        
        // 取消之前的渲染任务
        renderTasks[cacheKey]?.cancel()
        
        // 使用简单的异步任务而不是 DispatchWorkItem
        renderQueue.async { [weak self] in
            // 在开始渲染前检查任务是否已被取消
            guard let self = self, self.renderTasks[cacheKey] != nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            
            let image = self.renderPageToImage(page, size: size, scale: scale)
            
            DispatchQueue.main.async { [weak self] in
                // 再次检查任务是否仍然有效
                guard let self = self, self.renderTasks[cacheKey] != nil else {
                    completion(nil)
                    return
                }
                
                if let image = image {
                    let cost = Int(image.size.width * image.size.height * 4)
                    self.cache.setObject(image, forKey: cacheKey as NSString, cost: cost)
                }
                
                // 清理任务记录
                self.renderTasks.removeValue(forKey: cacheKey)
                completion(image)
            }
        }
        
        // 创建一个简单的标记来跟踪任务
        let dummyWorkItem = DispatchWorkItem {}
        renderTasks[cacheKey] = dummyWorkItem
    }
    
    private func renderPageToImage(_ page: PDFPage, size: CGSize, scale: CGFloat) -> UIImage? {
        let actualSize = CGSize(width: size.width * scale, height: size.height * scale)
        
        UIGraphicsBeginImageContextWithOptions(actualSize, true, 0)
        guard let context = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            return nil
        }
        
        // 设置白色背景
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: actualSize))
        
        // 保存图形状态
        context.saveGState()
        
        // 计算页面绘制区域
        let pageRect = page.bounds(for: .mediaBox)
        let scaleX = actualSize.width / pageRect.width
        let scaleY = actualSize.height / pageRect.height
        let drawScale = min(scaleX, scaleY)
        
        let drawSize = CGSize(
            width: pageRect.width * drawScale,
            height: pageRect.height * drawScale
        )
        
        let drawOrigin = CGPoint(
            x: (actualSize.width - drawSize.width) / 2,
            y: (actualSize.height - drawSize.height) / 2
        )
        
        // 设置变换
        context.translateBy(x: drawOrigin.x, y: drawOrigin.y + drawSize.height)
        context.scaleBy(x: drawScale, y: -drawScale)
        context.translateBy(x: -pageRect.minX, y: -pageRect.minY)
        
        // 绘制PDF页面
        page.draw(with: .mediaBox, to: context)
        
        // 恢复图形状态
        context.restoreGState()
        
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return image
    }
    
    private func cacheKeyFor(page: PDFPage, size: CGSize, scale: CGFloat) -> String {
        let pageLabel = page.label ?? "unknown"
        return "\(pageLabel)_\(Int(size.width))x\(Int(size.height))_\(scale)"
    }
    
    func cancelRenderTask(for key: String) {
        tasksQueue.async(flags: .barrier) { [weak self] in
            self?.renderTasks[key]?.cancel()
            self?.renderTasks.removeValue(forKey: key)
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - PDF阅读器主控制器
class PDFReaderViewController: UIViewController {
    
    // MARK: - Properties
    private var pageViewController: UIPageViewController!
    private var dataSource: PDFDataSource
    private var currentPageIndex: Int = 0
    private var pageCount: Int = 0
    
    // 视图控制器缓存
    private var pageViewControllers: [Int: PDFPageViewController] = [:]
    private let maxCacheSize = 5
    
    // UI Elements
    private var toolbarView: UIView!
    private var pageSlider: UISlider!
    private var pageLabel: UILabel!
    private var progressView: UIProgressView!
    
    // 设置
    private var isToolbarVisible = true
    private var autoHideTimer: Timer?
    
    // MARK: - Initializers
    init(pdfDocument: PDFDocument, initialPage: Int = 0) {
        self.dataSource = DefaultPDFDataSource(pdfDocument: pdfDocument)
        self.pageCount = pdfDocument.pageCount
        self.currentPageIndex = max(0, min(initialPage, pageCount - 1))
        super.init(nibName: nil, bundle: nil)
    }
    
    init(dataSource: PDFDataSource, initialPage: Int = 0) {
        self.dataSource = dataSource
        self.pageCount = dataSource.numberOfPages()
        self.currentPageIndex = max(0, min(initialPage, pageCount - 1))
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - View Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupPageViewController()
        setupToolbar()
        setupConstraints()
        updateUI()
        scheduleAutoHideToolbar()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        autoHideTimer?.invalidate()
        cleanupCache()
    }
    
    deinit {
        autoHideTimer?.invalidate()
        pageViewControllers.removeAll()
    }
    
    // MARK: - UI Setup
    private func setupUI() {
        view.backgroundColor = .systemBackground
        
        // 状态栏样式
        if #available(iOS 13.0, *) {
            overrideUserInterfaceStyle = .light
        }
    }
    
    private func setupPageViewController() {
        pageViewController = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .vertical,
            options: [UIPageViewController.OptionsKey.interPageSpacing: 10]
        )
        pageViewController.delegate = self
        pageViewController.dataSource = self
        
        // 设置初始页面
        if let initialViewController = pageViewController(at: currentPageIndex) {
            pageViewController.setViewControllers(
                [initialViewController],
                direction: .forward,
                animated: false,
                completion: nil
            )
        }
        
        addChild(pageViewController)
        view.addSubview(pageViewController.view)
        pageViewController.didMove(toParent: self)
    }
    
    private func setupToolbar() {
        // 工具栏背景
        toolbarView = UIView()
        toolbarView.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        toolbarView.layer.cornerRadius = 10
        view.addSubview(toolbarView)
        
        // 页面滑块
        pageSlider = UISlider()
        pageSlider.minimumValue = 0
        pageSlider.maximumValue = Float(max(0, pageCount - 1))
        pageSlider.value = Float(currentPageIndex)
        pageSlider.addTarget(self, action: #selector(pageSliderChanged(_:)), for: .valueChanged)
        pageSlider.addTarget(self, action: #selector(pageSliderTouchDown(_:)), for: .touchDown)
        pageSlider.addTarget(self, action: #selector(pageSliderTouchUp(_:)), for: [.touchUpInside, .touchUpOutside])
        toolbarView.addSubview(pageSlider)
        
        // 页面标签
        pageLabel = UILabel()
        pageLabel.textColor = .white
        pageLabel.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        pageLabel.textAlignment = .center
        toolbarView.addSubview(pageLabel)
        
        // 进度条
        progressView = UIProgressView(progressViewStyle: .default)
        progressView.progressTintColor = .systemBlue
        progressView.trackTintColor = UIColor.white.withAlphaComponent(0.3)
        view.addSubview(progressView)
        
        // 关闭按钮
        let closeButton = UIButton(type: .system)
        closeButton.setTitle("完成", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        closeButton.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)
        toolbarView.addSubview(closeButton)
        
        // 约束设置
        pageSlider.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            // 关闭按钮
            closeButton.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 50),
            
            // 页面标签
            pageLabel.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor, constant: -16),
            pageLabel.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            pageLabel.widthAnchor.constraint(equalToConstant: 80),
            
            // 页面滑块
            pageSlider.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 16),
            pageSlider.trailingAnchor.constraint(equalTo: pageLabel.leadingAnchor, constant: -16),
            pageSlider.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor)
        ])
    }
    
    private func setupConstraints() {
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        progressView.translatesAutoresizingMaskIntoConstraints = false
        pageViewController.view.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            // 页面视图控制器
            pageViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            pageViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            // 工具栏
            toolbarView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            toolbarView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            toolbarView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            toolbarView.heightAnchor.constraint(equalToConstant: 50),
            
            // 进度条
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        ])
    }
    
    // MARK: - 页面管理
    private func pageViewController(at index: Int) -> PDFPageViewController? {
        guard index >= 0 && index < pageCount else { return nil }
        
        // 检查缓存
        if let cachedViewController = pageViewControllers[index] {
            return cachedViewController
        }
        
        // 创建新的页面视图控制器
        guard let page = dataSource.pageAt(index: index) else { return nil }
        
        let pageVC = PDFPageViewController(page: page, pageIndex: index)
        pageVC.delegate = self
        
        // 添加到缓存
        if pageViewControllers.count >= maxCacheSize {
            // 移除最远的页面
            let currentIndices = Set(pageViewControllers.keys)
            if let farthestIndex = currentIndices.max(by: { abs($0 - currentPageIndex) < abs($1 - currentPageIndex) }) {
                pageViewControllers[farthestIndex]?.cleanup()
                pageViewControllers.removeValue(forKey: farthestIndex)
            }
        }
        
        pageViewControllers[index] = pageVC
        return pageVC
    }
    
    private func cleanupCache() {
        let indicesToKeep = Set([
            currentPageIndex - 1,
            currentPageIndex,
            currentPageIndex + 1
        ].filter { $0 >= 0 && $0 < pageCount })
        
        let indicesToRemove = Set(pageViewControllers.keys).subtracting(indicesToKeep)
        
        for index in indicesToRemove {
            pageViewControllers[index]?.cleanup()
            pageViewControllers.removeValue(forKey: index)
        }
    }
    
    // MARK: - UI更新
    private func updateUI() {
        pageLabel.text = "\(currentPageIndex + 1)/\(pageCount)"
        pageSlider.value = Float(currentPageIndex)
        progressView.progress = pageCount > 0 ? Float(currentPageIndex + 1) / Float(pageCount) : 0
        
        // 更新标题
        if let title = dataSource.documentTitle() {
            navigationItem.title = title
        }
    }
    
    private func scheduleAutoHideToolbar() {
        autoHideTimer?.invalidate()
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.hideToolbar()
        }
    }
    
    private func showToolbar() {
        guard !isToolbarVisible else { return }
        
        isToolbarVisible = true
        UIView.animate(withDuration: 0.3) {
            self.toolbarView.alpha = 1.0
            self.progressView.alpha = 1.0
        }
        scheduleAutoHideToolbar()
    }
    
    private func hideToolbar() {
        guard isToolbarVisible else { return }
        
        isToolbarVisible = false
        UIView.animate(withDuration: 0.3) {
            self.toolbarView.alpha = 0.0
            self.progressView.alpha = 0.0
        }
        autoHideTimer?.invalidate()
    }
    
    private func toggleToolbar() {
        if isToolbarVisible {
            hideToolbar()
        } else {
            showToolbar()
        }
    }
    
    // MARK: - Actions
    @objc private func pageSliderChanged(_ sender: UISlider) {
        let targetPage = Int(sender.value)
        pageLabel.text = "\(targetPage + 1)/\(pageCount)"
    }
    
    @objc private func pageSliderTouchDown(_ sender: UISlider) {
        autoHideTimer?.invalidate()
    }
    
    @objc private func pageSliderTouchUp(_ sender: UISlider) {
        let targetPage = Int(sender.value)
        goToPage(targetPage, animated: true)
        scheduleAutoHideToolbar()
    }
    
    @objc private func closeButtonTapped() {
        dismiss(animated: true)
    }
    
    private func goToPage(_ pageIndex: Int, animated: Bool) {
        guard pageIndex != currentPageIndex && pageIndex >= 0 && pageIndex < pageCount else { return }
        
        let direction: UIPageViewController.NavigationDirection = pageIndex > currentPageIndex ? .forward : .reverse
        
        if let targetViewController = pageViewController(at: pageIndex) {
            pageViewController.setViewControllers(
                [targetViewController],
                direction: direction,
                animated: animated
            ) { [weak self] _ in
                self?.didChangeToPage(pageIndex)
            }
        }
    }
    
    private func didChangeToPage(_ newPageIndex: Int) {
        currentPageIndex = newPageIndex
        updateUI()
        cleanupCache()
    }
    
    // MARK: - Status Bar
    override var prefersStatusBarHidden: Bool {
        return !isToolbarVisible
    }
    
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
        return .slide
    }
}

// MARK: - UIPageViewControllerDataSource
extension PDFReaderViewController: UIPageViewControllerDataSource {
    
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let pageVC = viewController as? PDFPageViewController else { return nil }
        let index = pageVC.pageIndex - 1
        return self.pageViewController(at: index)
    }
    
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let pageVC = viewController as? PDFPageViewController else { return nil }
        let index = pageVC.pageIndex + 1
        return self.pageViewController(at: index)
    }
}

// MARK: - UIPageViewControllerDelegate
extension PDFReaderViewController: UIPageViewControllerDelegate {
    
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        
        if completed,
           let currentViewController = pageViewController.viewControllers?.first as? PDFPageViewController {
            didChangeToPage(currentViewController.pageIndex)
        }
    }
}

// MARK: - PDFPageViewControllerDelegate
extension PDFReaderViewController: PDFPageViewControllerDelegate {
    
    func pdfPageViewControllerDidTap(_ controller: PDFPageViewController) {
        toggleToolbar()
        setNeedsStatusBarAppearanceUpdate()
    }
}

// MARK: - PDF页面视图控制器
protocol PDFPageViewControllerDelegate: AnyObject {
    func pdfPageViewControllerDidTap(_ controller: PDFPageViewController)
}

class PDFPageViewController: UIViewController {
    
    // MARK: - Properties
    weak var delegate: PDFPageViewControllerDelegate?
    private var scrollView: UIScrollView!
    private var imageView: UIImageView!
    private var loadingIndicator: UIActivityIndicatorView!
    
    private let pdfPage: PDFPage
    let pageIndex: Int
    private var isPageLoaded = false
    private var currentRenderScale: CGFloat = 1.0
    
    // MARK: - Initializers
    init(page: PDFPage, pageIndex: Int) {
        self.pdfPage = page
        self.pageIndex = pageIndex
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - View Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupConstraints()
        setupGestures()
        loadPage()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if isPageLoaded {
            updateZoomScale()
            centerImageView()
        }
    }
    
    deinit {
        cleanup()
    }
    
    // MARK: - Memory Management
    func cleanup() {
        imageView.image = nil
        isPageLoaded = false
    }
    
    // MARK: - UI Setup
    private func setupUI() {
        view.backgroundColor = .systemBackground
        
        // 加载指示器
        loadingIndicator = UIActivityIndicatorView(style: .large)
        loadingIndicator.color = .systemGray
        loadingIndicator.hidesWhenStopped = true
        view.addSubview(loadingIndicator)
        
        // 滚动视图
        scrollView = UIScrollView()
        scrollView.delegate = self
        scrollView.minimumZoomScale = 0.5
        scrollView.maximumZoomScale = 5.0
        scrollView.zoomScale = 1.0
        scrollView.showsVerticalScrollIndicator = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.isHidden = true
        
        // 图片视图
        imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        imageView.isUserInteractionEnabled = true
        
        view.addSubview(scrollView)
        scrollView.addSubview(imageView)
    }
    
    private func setupConstraints() {
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            // 加载指示器
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            
            // 滚动视图
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            // 图片视图
            imageView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor)
        ])
    }
    
    private func setupGestures() {
        // 双击缩放
        let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTapGesture.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTapGesture)
        
        // 单击
        let singleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTapGesture.numberOfTapsRequired = 1
        singleTapGesture.require(toFail: doubleTapGesture)
        scrollView.addGestureRecognizer(singleTapGesture)
    }
    
    // MARK: - 页面加载
    private func loadPage() {
        loadingIndicator.startAnimating()
        
        let viewSize = view.bounds.size
        let renderSize = viewSize.width > 0 ? viewSize : CGSize(width: 375, height: 667)
        
        PDFPageCache.shared.renderPage(pdfPage, at: renderSize, scale: currentRenderScale) { [weak self] image in
            self?.displayPage(image)
        }
    }
    
    private func displayPage(_ image: UIImage?) {
        loadingIndicator.stopAnimating()
        
        guard let image = image else {
            // 显示错误状态
            return
        }
        
        imageView.image = image
        isPageLoaded = true
        
        // 设置图片视图尺寸
        let imageSize = image.size
        imageView.frame = CGRect(origin: .zero, size: imageSize)
        scrollView.contentSize = imageSize
        
        // 显示滚动视图
        scrollView.isHidden = false
        
        updateZoomScale()
        centerImageView()
    }
    
    private func updateZoomScale() {
        guard let image = imageView.image else { return }
        
        let scrollViewFrame = scrollView.frame
        guard scrollViewFrame.width > 0 && scrollViewFrame.height > 0 else { return }
        
        let scaleWidth = scrollViewFrame.width / image.size.width
        let scaleHeight = scrollViewFrame.height / image.size.height
        let minScale = min(scaleWidth, scaleHeight)
        
        scrollView.minimumZoomScale = minScale
        scrollView.maximumZoomScale = max(minScale * 5, 5.0)
        
        // 设置初始缩放以适应页面宽度
        if scrollView.zoomScale < minScale {
            scrollView.setZoomScale(minScale, animated: false)
        }
    }
    
    private func centerImageView() {
        let scrollViewFrame = scrollView.frame
        let contentSize = scrollView.contentSize
        
        var imageViewFrame = imageView.frame
        
        if contentSize.width < scrollViewFrame.width {
            imageViewFrame.origin.x = (scrollViewFrame.width - contentSize.width) / 2
        } else {
            imageViewFrame.origin.x = 0
        }
        
        if contentSize.height < scrollViewFrame.height {
            imageViewFrame.origin.y = (scrollViewFrame.height - contentSize.height) / 2
        } else {
            imageViewFrame.origin.y = 0
        }
        
        imageView.frame = imageViewFrame
    }
    
    // MARK: - 手势处理
    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard isPageLoaded else { return }
        
        let location = gesture.location(in: imageView)
        
        if scrollView.zoomScale == scrollView.minimumZoomScale {
            // 放大到2倍
            let zoomScale = min(scrollView.maximumZoomScale, scrollView.minimumZoomScale * 2)
            let zoomRect = zoomRectForScale(zoomScale, center: location)
            scrollView.zoom(to: zoomRect, animated: true)
        } else {
            // 缩小到最小
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        }
    }
    
    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        delegate?.pdfPageViewControllerDidTap(self)
    }
    
    private func zoomRectForScale(_ scale: CGFloat, center: CGPoint) -> CGRect {
        let size = CGSize(
            width: scrollView.frame.width / scale,
            height: scrollView.frame.height / scale
        )
        
        let origin = CGPoint(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2
        )
        
        return CGRect(origin: origin, size: size)
    }
}

// MARK: - UIScrollViewDelegate
extension PDFPageViewController: UIScrollViewDelegate {
    
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return imageView
    }
    
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageView()
        
        // 检查是否需要重新渲染高质量版本
        let newRenderScale = scrollView.zoomScale
        if abs(newRenderScale - currentRenderScale) > 1.0 {
            currentRenderScale = newRenderScale
            
            // 延迟重新渲染以避免频繁调用
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.rerenderIfNeeded()
            }
        }
    }
    
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        centerImageView()
    }
    
    private func rerenderIfNeeded() {
        guard isPageLoaded else { return }
        
        let viewSize = scrollView.frame.size
        PDFPageCache.shared.renderPage(pdfPage, at: viewSize, scale: currentRenderScale) { [weak self] image in
            if let image = image {
                self?.imageView.image = image
            }
        }
    }
}

// MARK: - 使用示例
/*
// 基本使用 - 从本地PDF文件
guard let url = Bundle.main.url(forResource: "sample", withExtension: "pdf"),
      let pdfDocument = PDFDocument(url: url) else {
    return
}

let pdfReader = PDFReaderViewController(pdfDocument: pdfDocument)
let navController = UINavigationController(rootViewController: pdfReader)
navController.modalPresentationStyle = .fullScreen
present(navController, animated: true)

// 从URL加载PDF
let url = URL(string: "https://example.com/document.pdf")!
URLSession.shared.dataTask(with: url) { data, _, error in
    guard let data = data, let pdfDocument = PDFDocument(data: data) else { return }
    
    DispatchQueue.main.async {
        let pdfReader = PDFReaderViewController(pdfDocument: pdfDocument)
        let navController = UINavigationController(rootViewController: pdfReader)
        self.present(navController, animated: true)
    }
}.resume()

// 从指定页面开始阅读
let pdfReader = PDFReaderViewController(pdfDocument: pdfDocument, initialPage: 5)
*/
