//
//  SGViewController.h
//  SGProtocol
//
//  Created by Simon Grätzer on 24.08.12.
//  Copyright (c) 2012 Simon Grätzer. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface SGViewController : UIViewController <UIWebViewDelegate>
@property (weak, nonatomic) IBOutlet UIWebView *webView;

@end
