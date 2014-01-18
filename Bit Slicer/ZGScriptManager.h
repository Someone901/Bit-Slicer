/*
 * Created by Mayur Pawashe on 8/25/13.
 *
 * Copyright (c) 2013 zgcoder
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * Redistributions of source code must retain the above copyright notice,
 * this list of conditions and the following disclaimer.
 *
 * Redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution.
 *
 * Neither the name of the project's author nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
 * TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import <Foundation/Foundation.h>
#import "Python.h"
#import "ZGRegistersController.h"
#import "VDKQueue.h"
#import "ZGMemoryTypes.h"

@class ZGDocumentWindowController;
@class ZGVariable;
@class ZGProcess;

#define SCRIPT_EVALUATION_ERROR_REASON @"Reason"

@interface ZGScriptManager : NSObject <VDKQueueDelegate>

+ (PyObject *)compiledExpressionFromExpression:(NSString *)expression;

+ (BOOL)evaluateCondition:(PyObject *)compiledExpression process:(ZGProcess *)process registerEntries:(ZGFastRegisterEntry *)registerEntries error:(NSError **)error;

- (id)initWithWindowController:(ZGDocumentWindowController *)windowController;

- (void)cleanup;

- (void)loadCachedScriptsFromVariables:(NSArray *)variables;

- (void)openScriptForVariable:(ZGVariable *)variable;

- (void)runScriptForVariable:(ZGVariable *)variable;
- (void)stopScriptForVariable:(ZGVariable *)variable;

- (void)handleBreakPointDataAddress:(ZGMemoryAddress)dataAddress instructionAddress:(ZGMemoryAddress)instructionAddress sender:(id)sender;

@end
