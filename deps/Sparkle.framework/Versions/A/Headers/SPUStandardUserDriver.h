//
//  SPUStandardUserDriver.h
//  Sparkle
//
//  Created by Mayur Pawashe on 2/14/16.
//  Copyright © 2016 Sparkle Project. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "SPUUserDriver.h"
#import "SPUStandardUserDriverProtocol.h"
#import "SUExport.h"

NS_ASSUME_NONNULL_BEGIN

@protocol SPUStandardUserDriverDelegate;

/*!
 Sparkle's standard built-in user driver for updater interactions
 */
SU_EXPORT @interface SPUStandardUserDriver : NSObject <SPUUserDriver, SPUStandardUserDriverProtocol>

/*!
 Initializes a Sparkle's standard user driver for user update interactions
 
 @param hostBundle The target bundle of the host that is being updated.
 @param applicationBundle The application bundle designated for relaunching. Usually this can be the same as hostBundle. This may differ when updating a plug-in or other non-application bundle.
 @param delegate The delegate to this user driver. Pass nil if you don't want to provide one.
 */
- (instancetype)initWithHostBundle:(NSBundle *)hostBundle applicationBundle:(NSBundle *)applicationBundle delegate:(nullable id<SPUStandardUserDriverDelegate>)delegate;

@end

NS_ASSUME_NONNULL_END
