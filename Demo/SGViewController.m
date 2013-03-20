//
//  SGViewController.m
//  SGProtocol
//
//  Created by Simon Grätzer on 24.08.12.
//  Copyright (c) 2012 Simon Grätzer. All rights reserved.
//

#import "SGViewController.h"
#import "SGHTTPURLProtocol.h"

@interface SGViewController ()

@end

@implementation SGViewController
@synthesize webView;

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage
                                          sharedHTTPCookieStorage];
    [cookieStorage setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyAlways];
    
    [SGHTTPURLProtocol registerProtocol];
	// Do any additional setup after loading the view, typically from a nib.
    NSURLRequest *r = [NSURLRequest requestWithURL:
                       [NSURL URLWithString:@"http://www.pagetutor.com/keeper/mystash/secretstuff.html"]
                                       cachePolicy:NSURLCacheStorageAllowed
                                   timeoutInterval:10.];
    self.webView.scalesPageToFit = YES;
    self.webView.delegate = self;
    [self.webView loadRequest:r];
}

- (void)viewDidUnload
{
    self.webView.delegate = nil;
    [self setWebView:nil];
    [SGHTTPURLProtocol unregisterProtocol];
    [super viewDidUnload];
    // Release any retained subviews of the main view.
}

- (void)dealloc {
    self.webView.delegate = nil;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad || interfaceOrientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (void)webViewDidStartLoad:(UIWebView *)webView {
    //NSLog(@"Start loading page: %@", webView.request.URL);
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
}


- (void)webViewDidFinishLoad:(UIWebView *)webView {
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
}

- (void)webView:(UIWebView *)webView didFailLoadWithError:(NSError *)error {
    //ignore these
    if (error.code == NSURLErrorCancelled || [error.domain isEqualToString:@"WebKitErrorDomain"]) return;
    
    
    if ([error.domain isEqualToString:@"NSURLErrorDomain"])
    {
        
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Error loading page"
                                                        message:[error localizedDescription]
                                                       delegate:nil cancelButtonTitle:NSLocalizedString(@"OK", @"ok")
                                              otherButtonTitles: nil];
        [alert show];
        return;
    }
}

@end
