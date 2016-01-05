import Foundation
import WebKit
import Shared

func configureActiveCrashReporter(_:Bool?) {}

let kNotificationPageUnload = "kNotificationPageUnload"

func convertNavActionToWKType(type:UIWebViewNavigationType) -> WKNavigationType {
    return WKNavigationType(rawValue: type.rawValue)!
}

class ContainerWebView : WKWebView {
    weak var legacyWebView: BraveWebView?
}

var nullWebView: WKWebView = WKWebView()
var nullWKNavigation: WKNavigation = WKNavigation()

enum KVOStrings: String {
    case kvoCanGoBack = "canGoBack"
    case kvoCanGoForward = "canGoForward"
    case kvoLoading = "loading"
    case kvoURL = "URL"
    case kvoEstimatedProgress = "estimatedProgress"

    static let allValues = [kvoCanGoBack, kvoCanGoForward, kvoLoading, kvoURL, kvoEstimatedProgress]
}

class BraveWebView: UIWebView {
    let specialStopLoadUrl = "http://localhost.stop.load"
    static let kNotificationWebViewLoadCompleteOrFailed = "kNotificationWebViewLoadCompleteOrFailed"
    static let kContextMenuBlockNavigation = 8675309
    weak var navigationDelegate: WKNavigationDelegate?
    weak var UIDelegate: WKUIDelegate?
    lazy var configuration: BraveWebViewConfiguration = { return BraveWebViewConfiguration(webView: self) }()
    lazy var backForwardList: WebViewBackForwardList = { return WebViewBackForwardList(webView: self) } ()
    lazy var progress: WebViewProgress = { return WebViewProgress(parent: self) }()
    lazy var webViewDelegate: WebViewDelegate = { return WebViewDelegate(parent: self) }()

    var estimatedProgress: Double = 0
    var title: String = ""
    var URL: NSURL?
    var internalIsLoadingEndedFlag: Bool = false;
    var knownFrameContexts = Set<NSObject>()
    static var containerWebViewForCallbacks = { return ContainerWebView() }()
    // From http://stackoverflow.com/questions/14268230/has-anybody-found-a-way-to-load-https-pages-with-an-invalid-server-certificate-u
    var loadingUnvalidatedHTTPSPage: Bool = false

    // To mimic WKWebView we need this property. And, to easily overrride where Firefox code is setting it, we hack the setter,
    // so that a custom agent is set always to our kDesktopUserAgent.
    // A nil customUserAgent means to use the default which is correct.
    //TODO setting the desktop agent doesn't currently work, see note below)
    var customUserAgent:String? {
        willSet {
            if self.customUserAgent == newValue || newValue == nil {
                return
            }
            self.customUserAgent = newValue == nil ? nil : kDesktopUserAgent
            // The following doesn't work, we need to kill and restart the webview, and restore its history state
            // for this setting to take effect
            //      let defaults = NSUserDefaults(suiteName: AppInfo.sharedContainerIdentifier())!
            //      defaults.registerDefaults(["UserAgent": (self.customUserAgent ?? "")])
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    private func commonInit() {
        delegate = self.webViewDelegate
        scalesPageToFit = true

        scrollView.showsHorizontalScrollIndicator = false

        #if !TEST
            // if (BraveUX.IsHighLoadAnimationAllowed && !BraveUX.IsOverrideScrollingSpeedAndMakeSlower) {
            let rate = UIScrollViewDecelerationRateFast + (UIScrollViewDecelerationRateNormal - UIScrollViewDecelerationRateFast) * 0.5;
            scrollView.setValue(NSValue(CGSize: CGSizeMake(rate, rate)), forKey: "_decelerationFactor")
            //    } else {
            //      scrollView.decelerationRate = UIScrollViewDecelerationRateFast
            //    }
        #endif
        setupSwipeGesture()
    }

    func internalProgressNotification(notification: NSNotification) {
        //print("\(notification.userInfo?["WebProgressEstimatedProgressKey"])")
        if (notification.userInfo?["WebProgressEstimatedProgressKey"] as? Double ?? 0 > 0.99) {
            delegate?.webViewDidFinishLoad?(self)
        }
    }

    override var loading: Bool {
        get {
            if internalIsLoadingEndedFlag {
                // we detected load complete internally –UIWebView sometimes stays in a loading state (i.e. bbc.com)
                return false
            }
            return super.loading
        }
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        commonInit()
    }

    let internalProgressStartedNotification = "WebProgressStartedNotification"
    let internalProgressChangedNotification = "WebProgressEstimateChangedNotification"
    let internalProgressFinishedNotification = "WebProgressFinishedNotification" // Not usable

    override func loadRequest(request: NSURLRequest) {
        guard let internalWebView = valueForKeyPath("documentView.webView") else { return }
        NSNotificationCenter.defaultCenter().removeObserver(self, name: internalProgressChangedNotification, object: internalWebView)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: "internalProgressNotification:", name: internalProgressChangedNotification, object: internalWebView)

        if let url = request.URL where !url.absoluteString.contains(specialStopLoadUrl) {
            URL = request.URL
        }
        super.loadRequest(request)
    }

    func loadingCompleted() {
        if let nd = navigationDelegate {
            BraveWebView.containerWebViewForCallbacks.legacyWebView = self
            nd.webView?(BraveWebView.containerWebViewForCallbacks, didFinishNavigation: nullWKNavigation)
        }

        internalIsLoadingEndedFlag = true
        configuration.userContentController.injectJsIntoPage()
        NSNotificationCenter.defaultCenter().postNotificationName(BraveWebView.kNotificationWebViewLoadCompleteOrFailed, object: nil)
        LegacyUserContentController.injectJsIntoAllFrames(self, script: "document.body.style.webkitTouchCallout='none'")

        #if !TEST
            replaceImagesUsingTheVault(self)
        #endif
    }

    func kvoBroadcast(kvos: [KVOStrings]? = nil) {
        if let _kvos = kvos {
            for item in _kvos {
                willChangeValueForKey(item.rawValue)
                didChangeValueForKey(item.rawValue)
            }
        } else {
            // send all
            kvoBroadcast(KVOStrings.allValues)
        }
    }

    func setScalesPageToFit(setPages: Bool!) {
        self.scalesPageToFit = setPages
    }

    func canNavigateBackward() -> Bool {
        return self.canGoBack
    }

    func canNavigateForward() -> Bool {
        return self.canGoForward
    }

    func reloadFromOrigin() {
        progress.setProgress(0.3)
        self.reload()
    }

    override func stopLoading() {
        super.stopLoading()
        loadRequest(NSURLRequest(URL: NSURL(string: specialStopLoadUrl)!))
        self.progress.reset()
    }

    private func convertStringToDictionary(text: String?) -> [String:AnyObject]? {
        if let data = text?.dataUsingEncoding(NSUTF8StringEncoding) where text?.characters.count > 0 {
            do {
                let json = try NSJSONSerialization.JSONObjectWithData(data, options: .MutableContainers) as? [String:AnyObject]
                return json
            } catch {
                print("Something went wrong")
            }
        }
        return nil
    }

    func evaluateJavaScript(javaScriptString: String, completionHandler: ((AnyObject?, NSError?) -> Void)?) {
        let wrapped = "var result = \(javaScriptString); JSON.stringify(result)"
        let string = stringByEvaluatingJavaScriptFromString(wrapped)
        let dict = convertStringToDictionary(string)
        completionHandler?(dict, NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotOpenFile, userInfo: nil))
    }

    func goToBackForwardListItem(item: LegacyBackForwardListItem) {
        if let index = backForwardList.backList.indexOf(item) {
            let backCount = backForwardList.backList.count - index
            for _ in 0..<backCount {
                goBack()
            }
        } else if let index = backForwardList.forwardList.indexOf(item) {
            for _ in 0..<(index + 1) {
                goForward()
            }
        }
    }

    override func goBack() {
        // stop scrolling so the web view will respond faster
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        NSNotificationCenter.defaultCenter().postNotificationName(kNotificationPageUnload, object: self)
        super.goBack()
    }

    override func goForward() {
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        NSNotificationCenter.defaultCenter().postNotificationName(kNotificationPageUnload, object: self)
        super.goForward()
    }

    class func isTopFrameRequest(request:NSURLRequest) -> Bool {
        return request.URL == request.mainDocumentURL
    }

    func setupSwipeGesture() {
        let right = UISwipeGestureRecognizer(target: self, action: "swipeRight:")
        right.direction = .Right
        let left = UISwipeGestureRecognizer(target: self, action: "swipeLeft:")
        left.direction = .Left

        left.requireGestureRecognizerToFail(right)
        right.requireGestureRecognizerToFail(left)

        addGestureRecognizer(right)
        addGestureRecognizer(left)
    }

    @objc func swipeRight(gesture: UISwipeGestureRecognizer) {
        if canGoBack {
            goBack()
        }
    }

    @objc func swipeLeft(gesture: UISwipeGestureRecognizer) {
        if canGoForward {
            goForward()
        }
    }

    // Long press context menu text selection overriding
    override func canPerformAction(action: Selector, withSender sender: AnyObject?) -> Bool {
        if (action.description.lowercaseString.contains("define")) {
            // This action leads to searching in Safari
            // TODO replace with an action that keeps the search in our app
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }

    func injectCSS(css: String) {
        var js = "var script = document.createElement('style');"
        js += "script.type = 'text/css';"
        js += "script.innerHTML = '\(css)';"
        js += "document.head.appendChild(script);"
        LegacyUserContentController.injectJsIntoAllFrames(self, script: js)
    }

}

class WebViewDelegate: NSObject, UIWebViewDelegate {
    weak var parent:BraveWebView?

    class LegacyNavigationAction : WKNavigationAction {
        var writableRequest: NSURLRequest
        var writableType: WKNavigationType

        init(type: WKNavigationType, request: NSURLRequest) {
            writableType = type
            writableRequest = request
            super.init()
        }

        override var request: NSURLRequest { get { return writableRequest} }
        override var navigationType: WKNavigationType { get { return writableType } }
        override var sourceFrame: WKFrameInfo {
            get { return WKFrameInfo() }
        }
    }

    init(parent: BraveWebView) {
        self.parent = parent
    }

    var certificateInvalidConnection:NSURLConnection?

    func webView(webView: UIWebView,shouldStartLoadWithRequest request: NSURLRequest, navigationType: UIWebViewNavigationType ) -> Bool {
        guard let parent = parent else { return false }

        if AboutUtils.isAboutHomeURL(request.URL) {
            parent.progress.completeProgress()
        }

        if let url = request.URL where url.absoluteString.contains(parent.specialStopLoadUrl) {
            parent.progress.completeProgress()
            return false
        }

        if let contextMenu = parent.window?.rootViewController?.presentedViewController
            where contextMenu.view.tag == BraveWebView.kContextMenuBlockNavigation {
                // When showing a context menu, the webview will often still navigate (ex. news.google.com)
                // We need to block navigation using this tag.
                return false
        }

        if parent.loadingUnvalidatedHTTPSPage {
            certificateInvalidConnection = NSURLConnection(request: request, delegate: self)
            certificateInvalidConnection?.start()
            return false
        }

        var result = parent.progress.shouldStartLoadWithRequest(request, navigationType: navigationType)
        if !result {
            return false
        }

        if let nd = parent.navigationDelegate {
            let action:LegacyNavigationAction =
            LegacyNavigationAction(type: convertNavActionToWKType(navigationType), request: request)

            nd.webView?(nullWebView, decidePolicyForNavigationAction: action,
                decisionHandler: { (policy:WKNavigationActionPolicy) -> Void in
                    result = policy == .Allow
            })
        }

        let locationChanged = BraveWebView.isTopFrameRequest(request)
        if locationChanged {
            // TODO Maybe separate page unload from link clicked.
            NSNotificationCenter.defaultCenter().postNotificationName(kNotificationPageUnload, object: parent)
            parent.URL = request.URL
        }

        parent.kvoBroadcast()

        return result
    }


    func webViewDidStartLoad(webView: UIWebView) {
        parent?.backForwardList.update(webView)

        if let nd = parent?.navigationDelegate {
            nd.webView?(nullWebView, didStartProvisionalNavigation: nullWKNavigation)
        }
        parent?.progress.webViewDidStartLoad()
        parent?.kvoBroadcast([KVOStrings.kvoLoading])
    }

    func webViewDidFinishLoad(webView: UIWebView) {
        assert(NSThread.isMainThread())

        guard let parent = parent else { return }
        let readyState = parent.stringByEvaluatingJavaScriptFromString("document.readyState")?.lowercaseString

        //print("readyState:\(readyState)")

        parent.title = webView.stringByEvaluatingJavaScriptFromString("document.title") ?? ""
        if let item = parent.backForwardList.currentItem {
            item.title = parent.title
        }

        if let scrapedUrl = webView.stringByEvaluatingJavaScriptFromString("window.location.href") {
            if !parent.progress.pathContainsCompleted(scrapedUrl) {
                parent.URL = NSURL(string: scrapedUrl)
                if let item = parent.backForwardList.currentItem {
                    item.URL = parent.URL ?? item.URL
                }
            }
        }

        parent.progress.webViewDidFinishLoad(documentReadyState: readyState)

        parent.kvoBroadcast()
    }

    func webView(webView: UIWebView, didFailLoadWithError error: NSError?) {
        if (error?.code == NSURLErrorCancelled) {
            return
        }

        if (error?.domain == NSURLErrorDomain) {
            if (error?.code == NSURLErrorServerCertificateHasBadDate      ||
                error?.code == NSURLErrorServerCertificateUntrusted         ||
                error?.code == NSURLErrorServerCertificateHasUnknownRoot    ||
                error?.code == NSURLErrorServerCertificateNotYetValid)
            {
                guard let parent = parent, url = parent.URL else { return }

                let alert = UIAlertController(title: "Certificate Error", message: "The identity of \(url.absoluteString) can't be verified", preferredStyle: UIAlertControllerStyle.Alert)
                alert.addAction(UIAlertAction(title: "Cancel", style: UIAlertActionStyle.Default) {
                    handler in
                    parent.stopLoading()
                    // The current displayed url is wrong, so easiest hack is:
                    if (parent.canGoBack) { // I don't think the !canGoBack case needs handling
                        parent.goBack()
                        parent.goForward()
                    }
                    })
                alert.addAction(UIAlertAction(title: "Continue", style: UIAlertActionStyle.Default) {
                    handler in
                    parent.loadingUnvalidatedHTTPSPage = true;
                    parent.loadRequest(NSURLRequest(URL: url))
                    
                    })
                
                #if !TEST
                    parent.window?.rootViewController?.presentViewController(alert, animated: true, completion: nil)
                #endif
                return
            }
        }
        
        NSNotificationCenter.defaultCenter()
            .postNotificationName(BraveWebView.kNotificationWebViewLoadCompleteOrFailed, object: nil)
        if let nd = parent?.navigationDelegate {
            nd.webView?(nullWebView, didFailNavigation: nullWKNavigation,
                withError: error ?? NSError.init(domain: "", code: 0, userInfo: nil))
        }
        print("didFailLoadWithError: \(error)")
        parent?.progress.didFailLoadWithError()
        parent?.kvoBroadcast()
    }
}

extension WebViewDelegate : NSURLConnectionDelegate, NSURLConnectionDataDelegate {
    func connection(connection: NSURLConnection, willSendRequestForAuthenticationChallenge challenge: NSURLAuthenticationChallenge) {
        guard let trust = challenge.protectionSpace.serverTrust else { return }
        let cred = NSURLCredential(forTrust: trust)
        challenge.sender?.useCredential(cred, forAuthenticationChallenge: challenge)
    }
    
    func connection(connection: NSURLConnection, didReceiveResponse response: NSURLResponse) {
        guard let parent = parent, url = parent.URL else { return }
        parent.loadingUnvalidatedHTTPSPage = false
        parent.loadRequest(NSURLRequest(URL: url))
        certificateInvalidConnection?.cancel()
    }    
}
