//
//  LEANWebViewController.m
//  LeanIOS
//
//  Created by Weiyin He on 2/10/14.
// Copyright (c) 2014 GoNative.io LLC. All rights reserved.
//

#import <WebKit/WebKit.h>

#import "LEANWebViewController.h"
#import "LEANAppDelegate.h"
#import "LEANUtilities.h"
#import "LEANAppConfig.h"
#import "LEANMenuViewController.h"
#import "LEANNavigationController.h"
#import "LEANRootViewController.h"
#import "LEANWebFormController.h"
#import "NSURL+LEANUtilities.h"
#import "LEANCustomAction.h"
#import "LEANUrlInspector.h"
#import "LEANProfilePicker.h"
#import "LEANInstallation.h"
#import "LEANTabManager.h"
#import "LEANWebViewPool.h"
#import "LEANDocumentSharer.h"
#import "Reachability.h"

@interface LEANWebViewController () <UISearchBarDelegate, UIActionSheetDelegate, UIScrollViewDelegate, UITabBarDelegate, WKNavigationDelegate, WKUIDelegate>

@property IBOutlet UIWebView* webview;
@property WKWebView *wkWebview;

@property IBOutlet UIBarButtonItem* backButton;
@property IBOutlet UIBarButtonItem* forwardButton;
@property IBOutlet UINavigationItem* nav;
@property IBOutlet UIBarButtonItem* navButton;
@property IBOutlet UIActivityIndicatorView *activityIndicator;
@property NSArray *defaultLeftNavBarItems;
@property NSArray *defaultToolbarItems;
@property UIBarButtonItem *customActionButton;
@property NSArray *customActions;
@property UIBarButtonItem *searchButton;
@property UISearchBar *searchBar;
@property UIView *statusBarBackground;
@property UITabBar *tabBar;
@property UIBarButtonItem *shareButton;
@property UIBarButtonItem *refreshButton;

@property BOOL willBeLandscape;

@property NSURLRequest *currentRequest;
@property NSInteger urlLevel; // -1 for unknown
@property NSString *profilePickerJs;
@property NSString *analyticsJs;
@property NSTimer *timer;
@property BOOL startedLoading; // for transitions, keeps track of whether document.readystate has switched to "loading"
@property BOOL didLoadPage; // keep track of whether any page has loaded. If network reconnects, then will attempt reload if there is no page loaded
@property BOOL isPoolWebview;
@property UIView *defaultTitleView;
@property UIView *navigationTitleImageView;

@property NSString *postLoadJavascript;
@property NSString *postLoadJavascriptForRefresh;

@property BOOL visitedLoginOrSignup;

@end

@implementation LEANWebViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.checkLoginSignup = YES;
    
    LEANAppConfig *appConfig = [LEANAppConfig sharedAppConfig];
    
    // push login controller if it should be the first thing shown
    if (appConfig.loginIsFirstPage && [self isRootWebView]) {
        LEANWebFormController *wfc = [[LEANWebFormController alloc] initWithDictionary:appConfig.loginConfig title:appConfig.appName isLogin:YES];
        wfc.originatingViewController = self;
        [self.navigationController pushViewController:wfc animated:NO];
    }
    
    // set title to application title
    if ([appConfig.navTitles count] == 0) {
        self.navigationItem.title = appConfig.appName;
    }
    
    // dark theme
    if ([appConfig.iosTheme isEqualToString:@"dark"]) {
        self.view.backgroundColor = [UIColor blackColor];
    } else {
        self.view.backgroundColor = [UIColor whiteColor];
    }
    
    // configure zoomability
    self.webview.scalesPageToFit = appConfig.allowZoom;
    
    // hide button if no native nav
    if (!appConfig.showNavigationMenu) {
        self.navButton.customView = [[UIView alloc] init];
    }
    
    // add nav button
    if (appConfig.showNavigationMenu &&  [self isRootWebView]) {
        self.navButton = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"navImage"] style:UIBarButtonItemStyleBordered target:self action:@selector(showMenu)];
        // hack to space it a bit closer to the left edge
        UIBarButtonItem *negativeSpacer = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
        [negativeSpacer setWidth:-10];
        
        self.navigationItem.leftBarButtonItems = @[negativeSpacer, self.navButton];
    }
    self.defaultLeftNavBarItems = self.navigationItem.leftBarButtonItems;
    
    // profile picker
    if (appConfig.profilePickerJS && [appConfig.profilePickerJS length] > 0) {
        self.profilePickerJs = appConfig.profilePickerJS;
        self.profilePicker = [[LEANProfilePicker alloc] init];
    }
    
    if (appConfig.analytics) {
        NSString *distribution = [LEANInstallation info][@"distribution"];
        NSInteger idsite;
        if ([distribution isEqualToString:@"appstore"]) idsite = appConfig.idsite_prod;
        else idsite = appConfig.idsite_test;
        
        
        NSString *template = @"var _paq = _paq || []; "
        "_paq.push(['trackPageView']); "
        "_paq.push(['enableLinkTracking']); "
        "(function() { "
        "    var u = 'https://analytics.gonative.io/'; "
        "    _paq.push(['setTrackerUrl', u+'piwik.php']); "
        "    _paq.push(['setSiteId', %d]); "
        "    var d=document, g=d.createElement('script'), s=d.getElementsByTagName('script')[0]; g.type='text/javascript'; "
        "    g.defer=true; g.async=true; g.src=u+'piwik.js'; s.parentNode.insertBefore(g,s); "
        "})(); ";
        self.analyticsJs = [NSString stringWithFormat:template, idsite];
    }
    
    self.visitedLoginOrSignup = NO;
    
    // switch to wkwebview if on ios8
    if (appConfig.useWKWebView) {
        WKWebViewConfiguration *config = [[NSClassFromString(@"WKWebViewConfiguration") alloc] init];
        config.processPool = [LEANUtilities wkProcessPool];
        WKWebView *wv = [[NSClassFromString(@"WKWebView") alloc] initWithFrame:self.webview.frame configuration:config];
        [LEANUtilities configureWebView:wv];
        [self switchToWebView:wv showImmediately:NO];
    } else {
        // set self as webview delegate to handle start/end load events
        self.webview.delegate = self;
        self.webview.scrollView.bounces = NO;
        [LEANUtilities configureWebView:self.webview];
    }
    
    // load initial url
    self.urlLevel = -1;
    if (!self.initialUrl) {
        self.initialUrl = appConfig.initialURL;
    }
    [self loadUrl:self.initialUrl];
    
    // nav title image
    [self checkNavigationTitleImageForUrl:self.initialUrl];
    
    // hidden nav bar
    if (!appConfig.showNavigationBar && [self isRootWebView]) {
        UINavigationBar *bar = [[UINavigationBar alloc] init];
        if ([appConfig.iosTheme isEqualToString:@"dark"]) {
            bar.barStyle = UIBarStyleBlack;
        }
        self.statusBarBackground = bar;
        [self.view addSubview:self.statusBarBackground];
    }
    
    if (appConfig.searchTemplateURL) {
        self.searchButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSearch target:self action:@selector(searchPressed:)];
        self.searchBar = [[UISearchBar alloc] init];
        self.searchBar.showsCancelButton = NO;
        self.searchBar.delegate = self;
    }
    
    if (appConfig.showRefreshButton) {
        self.refreshButton = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"refresh"] style:UIBarButtonItemStylePlain target:self action:@selector(refreshPressed:)];
    }
    
    [self showNavigationItemButtonsAnimated:NO];
    [self buildDefaultToobar];
    [self adjustInsets];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveNotification:) name:kLEANAppConfigNotificationProcessedTabNavigation object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveNotification:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveNotification:) name:kReachabilityChangedNotification object:nil];
}

- (void)didReceiveNotification:(NSNotification*)notification
{
    if ([[notification name] isEqualToString:kLEANAppConfigNotificationProcessedTabNavigation]) {
        [self checkTabsForUrl:self.currentRequest.URL];
    }
    else if ([[notification name] isEqualToString:UIApplicationDidBecomeActiveNotification]) {
        [self retryFailedPage];
    }
    else if ([[notification name] isEqualToString:kReachabilityChangedNotification]) {
        [self retryFailedPage];
    }
}

- (void)retryFailedPage
{
    // if there is a page loaded, user can just retry navigation
    if (self.didLoadPage) return;
    
    // return if currently loading a page
    if (self.webview && self.webview.loading) return;
    if (self.wkWebview && self.wkWebview.isLoading) return;
    
    NetworkStatus status = [((LEANAppDelegate*)[UIApplication sharedApplication].delegate).internetReachability currentReachabilityStatus];
    
    if (status != NotReachable && self.currentRequest) {
        NSLog(@"Networking reconnect. Retrying previous failed request.");
        [self loadRequest:self.currentRequest];
    }
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    if ([self isRootWebView]) {
        [self.navigationController setNavigationBarHidden:![LEANAppConfig sharedAppConfig].showNavigationBar animated:YES];
    } else {
        [self.navigationController setNavigationBarHidden:NO animated:YES];
    }
    
    [self adjustInsets];
}

- (void)viewWillDisappear:(BOOL)animated
{
    if (self.isMovingFromParentViewController) {
        self.webview.delegate = nil;
        [self.webview stopLoading];
        [[NSNotificationCenter defaultCenter] postNotificationName:kLEANWebViewControllerUserFinishedLoading object:self];
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
    }
    [super viewWillDisappear:animated];
}

- (void) buildDefaultToobar
{
    NSMutableArray *array = [self.toolbarItems mutableCopy];
    
    if ([LEANAppConfig sharedAppConfig].showShareButton) {
        UIBarButtonItem *shareButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(buttonPressed:)];
        shareButton.tag = 3;
        [array addObject:[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil]];
        [array addObject:shareButton];
    }
    self.defaultToolbarItems = array;
    [self setToolbarItems:array animated:NO];
}

- (void) updateCustomActions
{
    // get custom actions
    self.customActions = [LEANCustomAction actionsForUrl:[[self.webview request] URL]];
   
    if ([self.customActions count] == 0) {
        // remove button
        [self setToolbarItems:self.defaultToolbarItems animated:YES];
        self.customActionButton = nil;
    } else {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeDetailDisclosure];
        [button addTarget:self action:@selector(showCustomActions:) forControlEvents:UIControlEventTouchUpInside];
        
        self.customActionButton = [[UIBarButtonItem alloc] initWithCustomView:button];
        
        NSMutableArray *array = [self.defaultToolbarItems mutableCopy];
        [array addObject:[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil]];
        [array addObject:self.customActionButton];
        [self setToolbarItems:array animated:YES];
    }
    
}

- (void)showCustomActions:(id)sender
{
    
    /*
    LEANCustomActionController *controller = [[LEANCustomActionController alloc] init];
    controller.view.opaque = NO;
    
    // fade in
    controller.view.alpha = 0.0;
    [self.view addSubview:controller.view];
    [UIView animateWithDuration:0.4 animations:^{
        controller.view.alpha = 1.0;
    }];

    [self.navigationController setToolbarHidden:YES animated:YES]; */
    
    UIActionSheet *actionSheet = [[UIActionSheet alloc] init];
    for (LEANCustomAction* action in self.customActions) {
        [actionSheet addButtonWithTitle:action.name];
    }
    actionSheet.cancelButtonIndex = [actionSheet addButtonWithTitle:@"Cancel"];
    
    actionSheet.delegate = self;
    
    [actionSheet showFromBarButtonItem:self.customActionButton animated:YES];
}

- (void)checkTabsForUrl:(NSURL*) url;
{
    if (![LEANAppConfig sharedAppConfig].tabMenus) {
        [self hideTabBar];
        return;
    }
    
    if (!self.tabBar) {
        self.tabBar = [[UITabBar alloc] init];
        
        if ([[LEANAppConfig sharedAppConfig].iosTheme isEqualToString:@"dark"]) {
            self.tabBar.barStyle = UIBarStyleBlack;
        } else {
            self.tabBar.barStyle = UIBarStyleDefault;
        }
        
        self.tabBar.delegate = self;
        self.tabBar.hidden = YES;
        self.tabBar.alpha = 0.0;
    }
    
    if (![self.tabBar isDescendantOfView:self.view]) {
        [self.view addSubview:self.tabBar];

    }
    
    if (!self.tabManager) {
        self.tabManager = [[LEANTabManager alloc] initWithTabBar:self.tabBar webviewController:self];
    }
    
    [self.tabManager didLoadUrl:url];
}

- (void)checkNavigationTitleImageForUrl:(NSURL*)url
{
    // show logo in navigation bar
    if ([[LEANAppConfig sharedAppConfig] shouldShowNavigationTitleImageForUrl:[url absoluteString]]) {
        // create the view if necesary
        if (!self.navigationTitleImageView) {
            UIImage *im = [LEANAppConfig sharedAppConfig].navigationTitleIcon;
            if (!im) im = [UIImage imageNamed:@"navbar_logo"];
            
            if (im) {
                CGRect bounds = CGRectMake(0, 0, 30 * im.size.width / im.size.height, 30);
                UIView *backView = [[UIView alloc] initWithFrame:bounds];
                UIImageView *iv = [[UIImageView alloc] initWithImage:im];
                iv.bounds = bounds;
                [backView addSubview:iv];
                iv.center = backView.center;
                self.navigationTitleImageView = backView;
            }
        }
        
        // set the view
        self.defaultTitleView = self.navigationTitleImageView;
        self.navigationItem.titleView = self.navigationTitleImageView;
    } else {
        self.defaultTitleView = nil;
        self.navigationItem.titleView = nil;
    }
}

- (void)hideTabBar
{
    if (!self.tabBar) {
        return;
    }
    
    if (!self.tabBar.hidden) {
        [UIView animateWithDuration:0.3 animations:^(void){
            self.tabBar.alpha = 0.0;
        }completion:^(BOOL finished){
            self.tabBar.hidden = YES;
            self.tabBar.frame = CGRectZero;
            [self adjustInsets];
        }];
    }
}

- (void)showTabBar
{
    [self.navigationController setToolbarHidden:YES animated:NO];
    
    if (self.tabBar.hidden) {
        self.tabBar.alpha = 0;
        self.tabBar.hidden = NO;
        self.tabBar.frame = CGRectMake(0, self.view.bounds.size.height - 49, self.view.bounds.size.width, 49);
        [UIView animateWithDuration:0.3 animations:^(void){
            self.tabBar.alpha = 1.0;
        } completion:^(BOOL finished){
            [self adjustInsets];
        }];
    }
}

- (void)adjustInsets
{
    CGFloat top = [self.topLayoutGuide length];

    CGFloat bottom = 0;
    if (self.tabBar && !self.tabBar.hidden) {
        bottom = MIN(self.tabBar.bounds.size.height, self.tabBar.bounds.size.width);
    }
    
    // the following line should not be necessary, but adding it helps prevent a black bar from flashing at the bottom of the screen for a fraction of a second.
    self.webview.scrollView.contentInset = UIEdgeInsetsMake(top, 0, -top + bottom, 0);
    self.webview.scrollView.contentInset = UIEdgeInsetsMake(top, 0, bottom, 0);
    self.webview.scrollView.scrollIndicatorInsets = UIEdgeInsetsMake(top, 0, bottom, 0);
    
    self.wkWebview.scrollView.contentInset = UIEdgeInsetsMake(top, 0, bottom, 0);
    self.wkWebview.scrollView.scrollIndicatorInsets = UIEdgeInsetsMake(top, 0, bottom, 0);
}

- (IBAction) buttonPressed:(id)sender
{
    switch ((long)[((UIBarButtonItem*) sender) tag]) {
        case 1:
            // back
            if (self.webview.canGoBack)
                [self.webview goBack];
            break;
            
        case 2:
            // forward
            if (self.webview.canGoForward)
                [self.webview goForward];
            break;
            
        case 3:
            //action
            [self sharePage];
            break;
            
        case 4:
            //search
            NSLog(@"search");
            break;
            
        case 5:
            //refresh
            if ([self.webview.request URL] && ![[[self.webview.request URL] absoluteString] isEqualToString:@""]) {
                [self.webview reload];
            }
            else {
                [self loadRequest:self.currentRequest];
            }
            break;
        
        default:
            break;
    }
    
}

- (void) searchPressed:(id)sender
{
    self.navigationItem.titleView = self.searchBar;
    UIBarButtonItem *cancelButton = [[UIBarButtonItem alloc] initWithTitle:@"Cancel" style:UIBarButtonItemStylePlain target:self action:@selector(searchCanceled)];
    
    [self.navigationItem setLeftBarButtonItems:nil animated:YES];
    [self.navigationItem setRightBarButtonItems:@[cancelButton] animated:YES];
    [self.searchBar becomeFirstResponder];
}

- (void) sharePressed:(UIBarButtonItem*)sender
{
    [[LEANDocumentSharer sharedSharer] shareRequest:self.currentRequest fromButton:sender];
}

- (void) showNavigationItemButtonsAnimated:(BOOL)animated
{
    //left
    [self.navigationItem setLeftBarButtonItems:self.defaultLeftNavBarItems animated:animated];
    
    NSMutableArray *buttons = [[NSMutableArray alloc] initWithCapacity:4];
    
    // right: search button
    if (self.searchButton) {
        [buttons addObject:self.searchButton];
    }
    
    // right: refresh button
    if (self.refreshButton) {
        [buttons addObject:self.refreshButton];
    }
    
    // right: chromecast button
    LEANAppDelegate *appDelegate = (LEANAppDelegate*)[[UIApplication sharedApplication] delegate];
    if (appDelegate.castController.castButton && !appDelegate.castController.castButton.customView.hidden) {
        [buttons addObject:appDelegate.castController.castButton];
    }
    
    // right: document share button
    if (self.shareButton) {
        [buttons addObject:self.shareButton];
    }
    
    
    [self.navigationItem setRightBarButtonItems:buttons animated:animated];
}

- (void) sharePage
{
    UIActivityViewController * avc = [[UIActivityViewController alloc]
                                      initWithActivityItems:@[[self.currentRequest URL]] applicationActivities:nil];
    [self presentViewController:avc animated:YES completion:nil];
    
}

- (void)refreshPressed:(id)sender
{
    [self loadRequest:self.currentRequest andJavascript:self.postLoadJavascriptForRefresh];
}

- (void) logout
{
    [self.webview stopLoading];
    [self.wkWebview stopLoading];
    // stop webview pools
    [[NSNotificationCenter defaultCenter] postNotificationName:kLEANWebViewControllerUserStartedLoading object:self];
    [[LEANWebViewPool sharedPool] flushAll];
    // stop login detection
    [[LEANLoginManager sharedManager] stopChecking];
    
    // clear cookies
    NSHTTPCookie *cookie;
    NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    for (cookie in [storage cookies]) {
        [storage deleteCookie:cookie];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    // load initial page in bottom webview
    [self.navigationController popToRootViewControllerAnimated:NO];
    [self.navigationController.viewControllers[0] loadUrl:[LEANAppConfig sharedAppConfig].initialURL];
    
    [(LEANMenuViewController*)self.frostedViewController.menuViewController updateMenuWithStatus:@"default"];
}

- (IBAction) showMenu
{
    [self.frostedViewController presentMenuViewController];
}

- (void) loadUrlString:(NSString*)url
{
    if ([url length] == 0) {
        return;
    }
    
    if ([url hasPrefix:@"javascript:"]) {
        NSString *js = [url substringFromIndex: [@"javascript:" length]];
        [self runJavascript:js];
    } else {
        [self loadUrl:[NSURL URLWithString:url]];
    }
}

- (void) loadUrl:(NSURL *)url
{
    [self loadRequest:[NSURLRequest requestWithURL:url]];
}


- (void) loadRequest:(NSURLRequest*) request
{
    [[NSNotificationCenter defaultCenter] postNotificationName:kLEANWebViewControllerUserStartedLoading object:self];
    [self.webview loadRequest:request];
    [self.wkWebview loadRequest:request];
    self.postLoadJavascript = nil;
    self.postLoadJavascriptForRefresh = nil;
}

- (void) loadUrl:(NSURL *)url andJavascript:(NSString *)js
{
    NSURL *currentUrl = nil;
    if (self.webview) {
        currentUrl = self.webview.request.URL;
    } else if (self.wkWebview) {
        currentUrl = self.wkWebview.URL;
    }
    
    if ([[currentUrl absoluteString] isEqualToString:[url absoluteString]]) {
        [self hideWebview];
        [self runJavascript:js];
        self.postLoadJavascriptForRefresh = js;
        [self showWebview];
    } else {
        self.postLoadJavascript = js;
        self.postLoadJavascriptForRefresh = js;
        NSURLRequest *request = [NSURLRequest requestWithURL:url];
        [[NSNotificationCenter defaultCenter] postNotificationName:kLEANWebViewControllerUserStartedLoading object:self];
        [self.webview loadRequest:request];
        [self.wkWebview loadRequest:request];
    }
}

- (void) loadRequest:(NSURLRequest *)request andJavascript:(NSString*)js
{
    self.postLoadJavascript = js;
    self.postLoadJavascriptForRefresh = js;
    [[NSNotificationCenter defaultCenter] postNotificationName:kLEANWebViewControllerUserStartedLoading object:self];
    [self.webview loadRequest:request];
    [self.wkWebview loadRequest:request];
}

- (void) runJavascript:(NSString *) script
{
    [self.webview stringByEvaluatingJavaScriptFromString:script];
    [self.wkWebview evaluateJavaScript:script completionHandler:nil];
}

// is this is the first LEANWebViewController in the navigation stack?
- (BOOL) isRootWebView
{
    for (UIViewController *vc in self.navigationController.viewControllers) {
        if ([vc isKindOfClass:[LEANWebViewController class]]) {
            return vc == self;
        }
    }
    
    return NO;
}

+ (NSInteger) urlLevelForUrl:(NSURL*)url;
{
    NSArray *entries = [LEANAppConfig sharedAppConfig].navStructureLevels;
    if (entries) {
        NSString *urlString = [url absoluteString];
        for (NSDictionary *entry in entries) {
            NSPredicate *predicate = entry[@"predicate"];
            if ([predicate evaluateWithObject:urlString]) {
                return [entry[@"level"] integerValue];
            }
        }
    }

    // return -1 for unknown
    return -1;
}

+ (NSString*) titleForUrl:(NSURL*)url
{
    NSArray *entries = [LEANAppConfig sharedAppConfig].navTitles;
    NSString *title;
    
    if (entries) {
        NSString *urlString = [url absoluteString];
        for (NSDictionary *entry in entries) {
            NSPredicate *predicate = entry[@"predicate"];
            if ([predicate evaluateWithObject:urlString]) {
                if (entry[@"title"]) {
                    title = entry[@"title"];
                }
                
                if (!title && entry[@"urlRegex"]) {
                    NSRegularExpression *regex = entry[@"urlRegex"];
                    NSTextCheckingResult *match = [regex firstMatchInString:urlString options:0 range:NSMakeRange(0, [urlString length])];
                    if ([match range].location != NSNotFound) {
                        NSString *temp = [urlString substringWithRange:[match rangeAtIndex:1]];
                        
                        // dashes to spaces, capitalize
                        temp = [temp stringByReplacingOccurrencesOfString:@"-" withString:@" "];
                        title = [LEANUtilities capitalizeWords:temp];
                    }
                    
                    // remove words from end of title
                    if (title && [entry[@"urlChompWords"] intValue] > 0) {
                        __block NSInteger numWords = 0;
                        __block NSRange lastWordRange = NSMakeRange(0, [title length]);
                        [title enumerateSubstringsInRange:NSMakeRange(0, [title length]) options:NSStringEnumerationByWords | NSStringEnumerationReverse usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
                            
                            numWords++;
                            if (numWords >= [entry[@"urlChompWords"] intValue]) {
                                lastWordRange = substringRange;
                                *stop = YES;
                            }
                        }];
                        
                        title = [title substringToIndex:lastWordRange.location];
                        title = [title stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceCharacterSet]];
                    }
                }
                
                break;
            }
        }
    }
    
    return title;
}

#pragma mark - Search Bar Delegate
- (void) searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
    // the default url character does not escape '/', so use this function. NSString is toll-free bridged with CFStringRef
    NSString *searchText = (NSString *)CFBridgingRelease(CFURLCreateStringByAddingPercentEscapes(NULL,(CFStringRef)searchBar.text,NULL,(CFStringRef)@"!*'();:@&=+$,/?%#[]",kCFStringEncodingUTF8 ));
    // the search template can have any allowable url character, but we need to escape unicode characters like '✓' so that the NSURL creation doesn't die.
    NSString *searchTemplate = (NSString *)CFBridgingRelease(CFURLCreateStringByAddingPercentEscapes(NULL,(CFStringRef)[LEANAppConfig sharedAppConfig].searchTemplateURL,(CFStringRef)@"!*'();:@&=+$,/?%#[]",NULL,kCFStringEncodingUTF8 ));
    NSURL *url = [NSURL URLWithString:[searchTemplate stringByAppendingString:searchText]];
    [self loadUrl:url];
    
    self.navigationItem.titleView = self.defaultTitleView;
    [self showNavigationItemButtonsAnimated:YES];
}

- (void) searchBarCancelButtonClicked:(UISearchBar *)searchBar
{
    [self searchCanceled];
}

- (void) searchCanceled
{
    self.navigationItem.titleView = self.defaultTitleView;
    [self showNavigationItemButtonsAnimated:YES];
}


#pragma mark - UIWebViewDelegate
- (BOOL) webView:(UIWebView *)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(UIWebViewNavigationType)navigationType
{
    BOOL isMainFrame = [[[request URL] absoluteString] isEqualToString:[[request mainDocumentURL] absoluteString]];
    BOOL isUserAction = navigationType == UIWebViewNavigationTypeLinkClicked || navigationType ==UIWebViewNavigationTypeFormSubmitted;
    return [self shouldLoadRequest:request isMainFrame:isMainFrame isUserAction:isUserAction];
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    BOOL isUserAction = navigationAction.navigationType == WKNavigationTypeLinkActivated || navigationAction.navigationType == WKNavigationTypeFormSubmitted;
    BOOL shouldLoad = [self shouldLoadRequest:navigationAction.request isMainFrame:navigationAction.targetFrame.isMainFrame isUserAction:isUserAction];
    if (shouldLoad) decisionHandler(WKNavigationActionPolicyAllow);
    else decisionHandler(WKNavigationActionPolicyCancel);
}

- (BOOL)shouldLoadRequest:(NSURLRequest*)request isMainFrame:(BOOL)isMainFrame isUserAction:(BOOL)isUserAction
{
    LEANAppConfig *appConfig = [LEANAppConfig sharedAppConfig];
    NSURL *url = [request URL];
    NSString *urlString = [url absoluteString];
    NSString* hostname = [url host];
    
//    NSLog(@"should start load %@ main %d action %d", url, isMainFrame, isUserAction);
    
    // simulator
    if ([url.scheme isEqualToString:@"gonative.io"]) {
        return YES;
    }
    
    // tel links
    if ([url.scheme isEqualToString:@"tel"]) {
        NSString *telNumber = url.resourceSpecifier;
        if ([telNumber length] > 0) {
            NSURL *telPromptUrl = [NSURL URLWithString:[NSString stringWithFormat:@"telprompt:%@", telNumber]];
            if ([[UIApplication sharedApplication] canOpenURL:telPromptUrl]) {
                [[UIApplication sharedApplication] openURL:telPromptUrl];
            } else if ([[UIApplication sharedApplication] canOpenURL:url]) {
                [[UIApplication sharedApplication] openURL:url];
            }
        }
        
        return NO;
    }
    
    // always allow iframes to load
    if (![urlString isEqualToString:[[request mainDocumentURL] absoluteString]]) {
        return YES;
    }
    
    // if same page with anchor tag, then allow to load (skip transition)
    NSURL *currentUrl = self.currentRequest.URL;
    if (url.fragment
        && [request.HTTPMethod isEqualToString:@"GET"]
        && [self.currentRequest.HTTPMethod isEqualToString:@"GET"]
        && [url.scheme isEqualToString:currentUrl.scheme]
        && [url.host isEqualToString:currentUrl.host]
        && [url.pathComponents isEqualToArray:currentUrl.pathComponents]
        && (url.parameterString == currentUrl.parameterString || [url.parameterString isEqualToString:currentUrl.parameterString])
        && (url.query == currentUrl.query || [url.query isEqualToString:currentUrl.query])) {
        return YES;
    }
    
    [[LEANUrlInspector sharedInspector] inspectUrl:url];
    
    // check redirects
    if (appConfig.redirects != nil) {
        NSString *to = [appConfig.redirects valueForKey:urlString];
        if (to) {
            url = [NSURL URLWithString:to];
            
            //            [webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:to]]];
            //            return false;
        }
    }
    
    // log out by clearing cookies
    if (urlString && [urlString caseInsensitiveCompare:@"file://gonative_logout"] == NSOrderedSame) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self logout];
        });
        return NO;
    }
    
    // checkLoginSignup might be NO when returning from login screen with loginIsFirstPage
    BOOL checkLoginSignup = self.checkLoginSignup;
    self.checkLoginSignup = YES;
    
    // log in
    if (checkLoginSignup && appConfig.loginConfig &&
        [url matchesPathOf:appConfig.loginURL]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showWebview];
        });
        
        if (appConfig.loginIsFirstPage) {
            if (self.currentRequest) {
                // this is not the first page loaded, so was probably called via Logout.
                
                // recheck status as it has probably changed
                [[LEANLoginManager sharedManager] checkLogin];
                
                LEANWebFormController *wfc = [[LEANWebFormController alloc] initWithDictionary:appConfig.loginConfig title:appConfig.appName isLogin:YES];
                
                wfc.originatingViewController = self;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.navigationController pushViewController:wfc animated:YES];
                });
            } else {
                // this is the first page loaded, which means that the form controller has already been pushed in viewDidLoad. Do nothing.
            }
            
            return NO;
        }
        
        LEANWebFormController *wfc = [[LEANWebFormController alloc] initWithDictionary:appConfig.loginConfig title:@"Log In" isLogin:YES];
        wfc.originatingViewController = self;
        if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
            UINavigationController *formSheet = [[UINavigationController alloc] initWithRootViewController:wfc];
            formSheet.modalPresentationStyle = UIModalPresentationFormSheet;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self presentViewController:formSheet animated:YES completion:nil];
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.navigationController pushViewController:wfc animated:YES];
            });
        }
        return NO;
    }
    
    // sign up
    if (checkLoginSignup && appConfig.signupURL &&
        [url matchesPathOf:appConfig.signupURL]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showWebview];
        });
        
        LEANWebFormController *wfc = [[LEANWebFormController alloc] initWithDictionary:appConfig.signupConfig title:@"Sign Up" isLogin:NO];
        wfc.originatingViewController = self;
        
        if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
            UINavigationController *formSheet = [[UINavigationController alloc] initWithRootViewController:wfc];
            formSheet.modalPresentationStyle = UIModalPresentationFormSheet;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self presentViewController:formSheet animated:YES completion:nil];
            });
        }
        else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.navigationController pushViewController:wfc animated:YES];
            });
        }
        return NO;
    }
    
    // other forms
    if (appConfig.interceptForms) {
        for (id form in appConfig.interceptForms) {
            if ([url matchesPathOf:[NSURL URLWithString:form[@"interceptUrl"]]]) {
                [self showWebview];
                
                LEANWebFormController *wfc = [[LEANWebFormController alloc] initWithJsonObject:form];
                wfc.originatingViewController = self;
                if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
                    UINavigationController *formSheet = [[UINavigationController alloc] initWithRootViewController:wfc];
                    formSheet.modalPresentationStyle = UIModalPresentationFormSheet;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self presentViewController:formSheet animated:YES completion:nil];
                        
                    });
                }
                else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.navigationController pushViewController:wfc animated:YES];
                    });
                }
                
                return NO;
            }
        }
    }
    
    
    // twitter app
    if ([hostname isEqualToString:@"twitter.com"] && [[[request URL] path] isEqualToString:@"/intent/tweet"])
    {
        NSDictionary* dict = [LEANUtilities dictionaryFromQueryString:[[request URL] query]];
        
        NSURL* url = [NSURL URLWithString:
                      [LEANUtilities addQueryStringToUrlString:@"twitter://post?"
                                                withDictionary:@{@"message": [NSString stringWithFormat:@"%@ %@ @%@",
                                                                              dict[@"text"],
                                                                              dict[@"url"],
                                                                              dict[@"via"]]}]];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([[UIApplication sharedApplication] canOpenURL:url])
                [[UIApplication sharedApplication] openURL:url];
            else
                [[UIApplication sharedApplication] openURL:[request URL]];
        });
        
        return NO;
    }
    
    // external sites: don't launch if in iframe.
    if (isUserAction || (isMainFrame && ![[request URL] matchesPathOf:[self.currentRequest URL]])) {
        // first check regexInternalExternal
        bool matchedRegex = NO;
        for (NSUInteger i = 0; i < [appConfig.regexInternalEternal count]; i++) {
            NSPredicate *predicate = appConfig.regexInternalEternal[i];
            if ([predicate evaluateWithObject:urlString]) {
                matchedRegex = YES;
                if (![appConfig.regexIsInternal[i] boolValue]) {
                    // external
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[UIApplication sharedApplication] openURL:[request URL]];
                    });
                    return NO;
                }
                break;
            }
        }
        
        if (!matchedRegex) {
            if (![hostname isEqualToString:appConfig.initialHost] &&
                ![hostname hasSuffix:[@"." stringByAppendingString:appConfig.initialHost]]) {
                // open in external web browser
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[UIApplication sharedApplication] openURL:[request URL]];
                });
                return NO;
            }
        }
    }
    
    // Starting here, we are going to load the request, but possibly in a different webviewcontroller depending on the structured nav level
    NSInteger newLevel = [LEANWebViewController urlLevelForUrl:url];
    if (self.urlLevel >= 0 && newLevel >= 0) {
        if (newLevel > self.urlLevel) {
            // push a new controller
            LEANWebViewController *newvc = [self.storyboard instantiateViewControllerWithIdentifier:@"webviewController"];
            newvc.initialUrl = url;
            newvc.postLoadJavascript = self.postLoadJavascript;
            self.postLoadJavascript = nil;
            self.postLoadJavascriptForRefresh = nil;
            
            NSMutableArray *controllers = [self.navigationController.viewControllers mutableCopy];
            while (![[controllers lastObject] isKindOfClass:[LEANWebViewController class]]) {
                [controllers removeLastObject];
            }
            [controllers addObject:newvc];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.navigationController setViewControllers:controllers animated:YES];
            });
            
            return NO;
        }
        else if (newLevel < self.urlLevel) {
            // find controller on top of the first controller with a lower-numbered level
            NSArray *vcs = self.navigationController.viewControllers;
            LEANWebViewController *wvc = self;
            for (NSInteger i = vcs.count - 1; i >= 0; i--) {
                if ([vcs[i] isKindOfClass:[LEANWebViewController class]]) {
                    if (newLevel > ((LEANWebViewController*)vcs[i]).urlLevel) {
                        break;
                    }
                    
                    // save into as the 'previous to last' controller
                    wvc = vcs[i];
                }
            }
            
            if (wvc != self) {
                wvc.urlLevel = newLevel;
                if (self.postLoadJavascript) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [wvc loadRequest:request andJavascript:self.postLoadJavascript];
                    });
                    self.postLoadJavascript = nil;
                    self.postLoadJavascriptForRefresh = nil;
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [wvc loadRequest:request];
                    });
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.navigationController popToViewController:wvc animated:YES];
                });
                return NO;
            }
        }
    }
    
    
    // Starting here, the request will be loaded in this webviewcontroller
    // pop to the top webviewcontroller in the stack
    NSMutableArray *controllers = [self.navigationController.viewControllers mutableCopy];
    BOOL changedControllerStack = NO;
    while (![[controllers lastObject] isKindOfClass:[LEANWebViewController class]]) {
        [controllers removeLastObject];
        changedControllerStack = YES;
    }
    if (changedControllerStack) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.navigationController setViewControllers:controllers animated:YES];
        });
    }
    
    if (newLevel >= 0) {
        self.urlLevel = [LEANWebViewController urlLevelForUrl:url];
    }
    
    NSString *newTitle = [LEANWebViewController titleForUrl:url];
    if (newTitle) {
        self.navigationItem.title = newTitle;
    }
    
    
    // save request for various functions that require the current request
    NSURLRequest *previousRequest = self.currentRequest;
    self.currentRequest = request;
    // save for html interception
    ((LEANAppDelegate*)[[UIApplication sharedApplication] delegate]).currentRequest = request;
    
    // update title image
    [self checkNavigationTitleImageForUrl:request.URL];
    
    // check to see if the webview exists in pool. Swap it in if it's not the same url.
    UIView *poolWebview = nil;
    LEANWebViewPoolDisownPolicy poolDisownPolicy;
    poolWebview = [[LEANWebViewPool sharedPool] webviewForUrl:url policy:&poolDisownPolicy];
    
    if (poolWebview && poolDisownPolicy == LEANWebViewPoolDisownPolicyAlways) {
        self.isPoolWebview = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self switchToWebView:poolWebview showImmediately:YES];
            self.didLoadPage = YES;
            [self checkTabsForUrl:url];
        });
        [[LEANWebViewPool sharedPool] disownWebview:poolWebview];
        [[NSNotificationCenter defaultCenter] postNotificationName:kLEANWebViewControllerUserFinishedLoading object:self];
        return NO;
    }
    
    if (poolWebview && poolDisownPolicy == LEANWebViewPoolDisownPolicyNever) {
        self.isPoolWebview = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self switchToWebView:poolWebview showImmediately:YES];
            self.didLoadPage = YES;
            [self checkTabsForUrl:url];
        });
        return NO;
    }
    
    if (poolWebview && poolDisownPolicy == LEANWebViewPoolDisownPolicyReload &&
        ![[request URL] matchesPathOf:[previousRequest URL]]) {
        self.isPoolWebview = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self switchToWebView:poolWebview showImmediately:YES];
            self.didLoadPage = YES;
            [self checkTabsForUrl:url];
        });
        return NO;
    }
    
    if (self.isPoolWebview) {
        // if we are here, either the policy is reload and we are reloading the page, or policy is never but we are going to a different page. So take ownership of the webview.
        [[LEANWebViewPool sharedPool] disownWebview:self.webview];
        [[LEANWebViewPool sharedPool] disownWebview:self.wkWebview];
        self.isPoolWebview = NO;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self hideWebview];
        [self setNavigationButtonStatus];
    });
    
    [[NSNotificationCenter defaultCenter] postNotificationName:kLEANWebViewControllerUserStartedLoading object:self];
    
    return YES;
}

- (void)switchToWebView:(UIView*)newView showImmediately:(BOOL)showImmediately
{
    UIView *oldView;
    if (self.webview) {
        oldView = self.webview;
        ((UIWebView*)oldView).delegate = nil;
    }
    if (self.wkWebview) {
        oldView = self.wkWebview;
    }
    
    [self hideWebview];
    
    UIScrollView *scrollView;
    if ([newView isKindOfClass:[UIWebView class]]) {
        self.webview = (UIWebView*)newView;
        self.wkWebview = nil;
        self.webview.delegate = self;
        scrollView = self.webview.scrollView;
    } else if ([newView isKindOfClass:[NSClassFromString(@"WKWebView") class]]) {
        self.wkWebview = (WKWebView*)newView;
        self.webview = nil;
        self.wkWebview.navigationDelegate = self;
        self.wkWebview.UIDelegate = self;
        scrollView = self.wkWebview.scrollView;
    } else {
        return;
    }
    
    // scroll before swapping to help reduce jank
    [scrollView scrollRectToVisible:CGRectMake(0, 0, 1, 1) animated:NO];
    
    if (oldView != newView) {
        newView.frame = oldView.frame;
        [self.view insertSubview:newView aboveSubview:oldView];
        [oldView removeFromSuperview];
    }
    [self adjustInsets];
    // re-scroll after adjusting insets
    [scrollView scrollRectToVisible:CGRectMake(0, 0, 1, 1) animated:NO];
    
    // add layout constraints
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:newView attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeTop multiplier:1 constant:0]];
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:newView attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeBottom multiplier:1 constant:0]];
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:newView attribute:NSLayoutAttributeLeading relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeLeading multiplier:1 constant:0]];
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:newView attribute:NSLayoutAttributeTrailing relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeTrailing multiplier:1 constant:0]];
    
    if (self.postLoadJavascript) {
        [self runJavascript:self.postLoadJavascript];
        self.postLoadJavascript = nil;
    }
    
    // fix for black boxes
    for (UIView *view in scrollView.subviews) {
        [view setNeedsDisplayInRect:newView.bounds];
    }
    
    if (showImmediately) {
        [self showWebview];
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
    }
}

- (void) webViewDidStartLoad:(UIWebView *)webView
{
    [self didStartLoad];
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation
{
    [self didStartLoad];
}

- (void)didStartLoad
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
        [self.customActionButton setEnabled:NO];
        
        [self.timer invalidate];
        self.timer = [NSTimer timerWithTimeInterval:0.05 target:self selector:@selector(checkReadyStatus) userInfo:nil repeats:YES];
        [self.timer setTolerance:0.02];
        [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSDefaultRunLoopMode];
        
        // remove share button
        if (self.shareButton) {
            self.shareButton = nil;
            [self showNavigationItemButtonsAnimated:YES];
        }
    });
}

- (void) webViewDidFinishLoad:(UIWebView *)webView
{
    [self didFinishLoad];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    [self didFinishLoad];
}

- (void)didFinishLoad
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self showWebview];
        self.didLoadPage = YES;
        
        NSURL *url = nil;
        if (self.webview) {
            url = self.webview.request.URL;
        } else if (self.wkWebview) {
            url = self.wkWebview.URL;
        }
        [[LEANUrlInspector sharedInspector] inspectUrl:url];
        
        
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
        [self setNavigationButtonStatus];
        
        [LEANUtilities addJqueryToWebView:self.webview];
        [LEANUtilities addJqueryToWebView:self.wkWebview];
        
        // update navigation title
        if ([LEANAppConfig sharedAppConfig].useWebpageTitle) {
            if (self.webview) {
                NSString *theTitle=[self.webview stringByEvaluatingJavaScriptFromString:@"document.title"];
                self.nav.title = theTitle;
            }
            else if (self.wkWebview) {
                self.nav.title = self.wkWebview.title;
            }
        }
        
        // update menu
        if ([LEANAppConfig sharedAppConfig].loginDetectionURL && (!self.webview || !self.webview.isLoading)) {
            [[LEANLoginManager sharedManager] checkLogin];
            
            self.visitedLoginOrSignup = [url matchesPathOf:[LEANAppConfig sharedAppConfig].loginURL] ||
            [url matchesPathOf:[LEANAppConfig sharedAppConfig].signupURL];
        }
        
        // dynamic config updater
        if ([LEANAppConfig sharedAppConfig].updateConfigJS && (!self.webview || !self.webview.isLoading)) {
            if (self.webview) {
                NSString *result = [self.webview stringByEvaluatingJavaScriptFromString:[LEANAppConfig sharedAppConfig].updateConfigJS];
                [[LEANAppConfig sharedAppConfig] processDynamicUpdate:result];
            }
            if (self.wkWebview) {
                [self.wkWebview evaluateJavaScript:[LEANAppConfig sharedAppConfig].updateConfigJS completionHandler:^(id response, NSError *error) {
                    if ([response isKindOfClass:[NSString class]]) {
                        [[LEANAppConfig sharedAppConfig] processDynamicUpdate:response];
                    }
                }];
            }
        }
        
        // profile picker
        if (self.profilePickerJs) {
            if (self.webview) {
                NSString *json = [self.webview stringByEvaluatingJavaScriptFromString:self.profilePickerJs];
                [self.profilePicker parseJson:json];
                
            }
            if (self.wkWebview) {
                [self.wkWebview evaluateJavaScript:self.profilePickerJs completionHandler:^(id response, NSError *error) {
                    if ([response isKindOfClass:[NSString class]]) {
                        [self.profilePicker parseJson:response];
                    }
                }];
            }
            
            [(LEANMenuViewController*)self.frostedViewController.menuViewController showSettings:[self.profilePicker hasProfiles]];
        }
        
        // analytics
        if (self.analyticsJs && (!self.webview || !self.webview.isLoading)) {
            [self runJavascript:self.analyticsJs];
        }
        
        if ([LEANAppConfig sharedAppConfig].enableChromecast) {
            [self detectVideo];
            // [self performSelector:@selector(detectVideo) withObject:nil afterDelay:1];
        }
        
        [self updateCustomActions];
        
        // tabs
        [self checkTabsForUrl: url];
        
        // post-load js
        if (self.postLoadJavascript && (!self.webview || !self.webview.isLoading)) {
            NSString *js = self.postLoadJavascript;
            self.postLoadJavascript = nil;
            [self runJavascript:js];
        }
        
        // post notification
        if (!self.webview || !self.webview.isLoading) {
            [[NSNotificationCenter defaultCenter] postNotificationName:kLEANWebViewControllerUserFinishedLoading object:self];
        }
        
        // document sharing
        if ([[LEANDocumentSharer sharedSharer] isSharableRequest:self.currentRequest]) {
            if (!self.shareButton) {
                self.shareButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(sharePressed:)];
                [self showNavigationItemButtonsAnimated:YES];
            }
        } else {
            self.shareButton = nil;
            [self showNavigationItemButtonsAnimated:YES];
        }

        // save session cookies as persistent
        NSUInteger forceSessionCookieExpiry = [LEANAppConfig sharedAppConfig].forceSessionCookieExpiry;
        if (forceSessionCookieExpiry > 0) {
            NSHTTPCookieStorage *cookieStore = [NSHTTPCookieStorage sharedHTTPCookieStorage];
            for (NSHTTPCookie *cookie in [cookieStore cookiesForURL:url]) {
                if (cookie.expiresDate == nil || cookie.sessionOnly) {
                    NSMutableDictionary *cookieProperties = [cookie.properties mutableCopy];
                    cookieProperties[NSHTTPCookieExpires] = [[NSDate date] dateByAddingTimeInterval:forceSessionCookieExpiry];
                    cookieProperties[NSHTTPCookieMaximumAge] = [NSString stringWithFormat:@"%lu", (unsigned long)forceSessionCookieExpiry];
                    [cookieProperties removeObjectForKey:@"Created"];
                    [cookieProperties removeObjectForKey:NSHTTPCookieDiscard];
                    NSHTTPCookie *newCookie = [NSHTTPCookie cookieWithProperties:cookieProperties];
                    [cookieStore setCookie:newCookie];
                }
            }
        }
    });
}

- (WKWebView*)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures
{
    WKWebView *wv = [[NSClassFromString(@"WKWebView") alloc] initWithFrame:self.webview.frame configuration:configuration];
    [LEANUtilities configureWebView:wv];
    [self switchToWebView:wv showImmediately:NO];
    return wv;
}

- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)())completionHandler
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:frame.request.URL.host message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        completionHandler();
    }];
    [alert addAction:okAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)checkReadyStatus
{
    // if interactiveDelay is specified, then look for readyState=interactive, and show webview
    // with a delay. If not specified, wait for readyState=complete.
    NSNumber *interactiveDelay = [LEANAppConfig sharedAppConfig].interactiveDelay;
    
    void (^readyStateBlock)(id, NSError*) = ^(id status, NSError *error) {
        // we keep track of startedLoading because loading is only really finished when we have gone to
        // "loading" or "interactive" before going to complete. When the web page first starts loading,
        // it will be in "complete", then "loading", "interactive", and finally "complete".
        
        if (![status isKindOfClass:[NSString class]]) {
            return;
        }
        
        if ([status isEqualToString:@"loading"] || (!interactiveDelay && [status isEqualToString:@"interactive"])){
            self.startedLoading = YES;
        }
        else if ((interactiveDelay && [status isEqualToString:@"interactive"])
                 || (self.startedLoading && [status isEqualToString:@"complete"])) {
            
            self.didLoadPage = YES;
            
            if ([status isEqualToString:@"interactive"]){
                // note: doubleValue will be 0 if interactiveDelay is null
                [self showWebviewWithDelay:[interactiveDelay doubleValue]];
            }
            else {
                [self showWebview];
            }
        }
    };
    
    if (self.webview) {
        NSString *readyState = [self.webview stringByEvaluatingJavaScriptFromString:@"document.readyState"];
        readyStateBlock(readyState, nil);
    } else if (self.wkWebview) {
        [self.wkWebview evaluateJavaScript:@"document.readyState" completionHandler:readyStateBlock];
    }
}

- (void)hideWebview
{
    self.webview.alpha = 0.0;
    self.webview.userInteractionEnabled = NO;
    
    self.wkWebview.alpha = 0.0;
    self.wkWebview.userInteractionEnabled = NO;
    
    self.activityIndicator.alpha = 1.0;
    [self.activityIndicator startAnimating];
}

- (void)showWebview
{
    self.startedLoading = NO;
    [self.timer invalidate];
    self.timer = nil;
    self.webview.userInteractionEnabled = YES;
    self.wkWebview.userInteractionEnabled = YES;
    
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionAllowUserInteraction animations:^(void){
        self.webview.alpha = 1.0;
        self.wkWebview.alpha = 1.0;
        self.activityIndicator.alpha = 0.0;
    } completion:^(BOOL finished){
        [self.activityIndicator stopAnimating];
    }];
}

- (void)showWebviewWithDelay:(NSTimeInterval)delay
{
    [self performSelector:@selector(showWebview) withObject:nil afterDelay:delay];
}

- (void)webView:(UIWebView *)webView didFailLoadWithError:(NSError *)error
{
    [self didFailLoadWithError:error];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    [self didFailLoadWithError:error];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    [self didFailLoadWithError:error];
}

- (void)didFailLoadWithError:(NSError*)error
{
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
    
    // show webview unless navigation was canceled, which is most likely due to a different page being requested
    if (![error.domain isEqualToString:NSURLErrorDomain] || error.code != NSURLErrorCancelled) {
        [self showWebview];
    }
    
    if ([[error domain] isEqualToString:NSURLErrorDomain] && [error code] == NSURLErrorNotConnectedToInternet) {
        [[[UIAlertView alloc] initWithTitle:@"No connection" message:[error localizedDescription] delegate:nil cancelButtonTitle:@"OK" otherButtonTitles: nil] show];
    }
}

- (void)detectVideo
{
    NSString *dataUrlJs = @"jwplayer().config.fallbackDiv.getAttribute('data-url_alt');";
    NSString *titleJs = @"jwplayer().config.fallbackDiv.getAttribute('data-title');";
    
    LEANAppDelegate *appDelegate = (LEANAppDelegate*)[[UIApplication sharedApplication] delegate];
    LEANCastController *castController = appDelegate.castController;
    
    if (self.webview) {
        NSURL *url = nil;
        NSString *title = nil;
        NSString *dataurl = [self.webview stringByEvaluatingJavaScriptFromString:dataUrlJs];
        
        if (dataurl && [dataurl length] > 0) {
            url = [NSURL URLWithString:dataurl relativeToURL:self.currentRequest.URL];
            title = [self.webview stringByEvaluatingJavaScriptFromString:titleJs];
        }
        
        castController.urlToPlay = url;
        castController.titleToPlay = title;

    }
    else if (self.wkWebview) {
        [self.wkWebview evaluateJavaScript:dataUrlJs completionHandler:^(id result, NSError *error) {
            if ([result isKindOfClass:[NSString class]] && [result length] > 0) {
                NSURL *url = [NSURL URLWithString:result relativeToURL:self.currentRequest.URL];
                
                [self.wkWebview evaluateJavaScript:titleJs completionHandler:^(id result2, NSError *error2) {
                    castController.urlToPlay = url;
                    castController.titleToPlay = result2;
                }];
                
            } else {
                castController.urlToPlay = nil;
                castController.titleToPlay = nil;
            }
        }];
    }
}

- (void) setNavigationButtonStatus
{
    self.backButton.enabled = self.webview.canGoBack;
    self.forwardButton.enabled = self.webview.canGoForward;
}


- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

#pragma mark - Action Sheet Delegate
- (void)actionSheet:(UIActionSheet *)actionSheet didDismissWithButtonIndex:(NSInteger)buttonIndex
{
    if (buttonIndex < [self.customActions count]) {
        LEANCustomAction *action = self.customActions[buttonIndex];
        [self.webview stringByEvaluatingJavaScriptFromString:action.javascript];
    }
}

#pragma mark - Scroll View Delegate

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    if (scrollView.contentOffset.y > 0) {
        [self.navigationController setNavigationBarHidden:YES animated:YES];
        [self.navigationController setToolbarHidden:YES animated:YES];
        [scrollView setContentInset:UIEdgeInsetsMake(0, 0, 0, 0)];
        
    } else {
        [self.navigationController setNavigationBarHidden:NO animated:YES];
        [self.navigationController setToolbarHidden:NO animated:YES];
        [scrollView setContentInset:UIEdgeInsetsMake(64, 0, 44, 0)];
    }
}

- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
    self.willBeLandscape = toInterfaceOrientation == UIInterfaceOrientationLandscapeLeft || toInterfaceOrientation == UIInterfaceOrientationLandscapeRight;
    [self setNeedsStatusBarAppearanceUpdate];
}

- (BOOL)prefersStatusBarHidden
{
    if ( UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad )
    {
        return NO;
    } else {
        return self.willBeLandscape;
    }
}

- (UIStatusBarStyle)preferredStatusBarStyle
{
    if ([[LEANAppConfig sharedAppConfig].iosTheme isEqualToString:@"dark"]) {
        return UIStatusBarStyleLightContent;
    } else {
        return UIStatusBarStyleDefault;
    }
}

- (void)didRotateFromInterfaceOrientation:(UIInterfaceOrientation)fromInterfaceOrientation
{
    [super didRotateFromInterfaceOrientation:fromInterfaceOrientation];
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation duration:(NSTimeInterval)duration
{
    [self adjustInsets];
}

- (void)viewWillLayoutSubviews
{
    if (self.statusBarBackground) {
        // fix sizing (usually because of rotation) when navigation bar is hidden
        CGSize statusSize = [UIApplication sharedApplication].statusBarFrame.size;
        CGFloat height = 20;
        CGFloat width = MAX(statusSize.height, statusSize.width);
        self.statusBarBackground.frame = CGRectMake(0, 0, width, height);
    }
    [self adjustInsets];
}


@end
