/*
 * Created by Mayur Pawashe on 12/27/12.
 *
 * Copyright (c) 2012 zgcoder
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

#import "ZGDebuggerController.h"
#import "ZGAppController.h"
#import "ZGProcess.h"
#import "ZGRegion.h"
#import "ZGCalculator.h"
#import "ZGRunningProcess.h"
#import "ZGInstruction.h"
#import "ZGBreakPoint.h"
#import "ZGBreakPointController.h"
#import "ZGDisassemblerObject.h"
#import "ZGUtilities.h"
#import "ZGRegistersController.h"
#import "ZGPreferencesController.h"
#import "ZGBacktraceController.h"
#import "ZGMemoryViewerController.h"
#import "NSArrayAdditions.h"
#import "ZGVirtualMemory.h"
#import "ZGVirtualMemoryHelpers.h"

@interface ZGDebuggerController ()

@property (assign) IBOutlet NSTableView *instructionsTableView;
@property (assign) IBOutlet NSProgressIndicator *dissemblyProgressIndicator;
@property (assign) IBOutlet NSButton *stopButton;
@property (assign) IBOutlet NSSplitView *splitView;

@property (assign) IBOutlet ZGBacktraceController *backtraceController;
@property (assign) IBOutlet ZGRegistersController *registersController;

@property (nonatomic) NSArray *instructions;

@property (nonatomic) ZGCodeInjectionWindowController *codeInjectionController;

@property (nonatomic) NSArray *haltedBreakPoints;
@property (nonatomic, readonly) ZGBreakPoint *currentBreakPoint;

@property (nonatomic, assign) BOOL shouldIgnoreTableViewSelectionChange;

@end

#define ZGDebuggerAddressField @"ZGDisassemblerAddressField"
#define ZGDebuggerProcessName @"ZGDisassemblerProcessName"

#define ATOS_PATH @"/usr/bin/atos"

#define NOP_VALUE 0x90

@implementation ZGDebuggerController

#pragma mark Birth & Death

- (id)init
{
	self = [super init];
	
	if (self)
	{
		self.haltedBreakPoints = [[NSArray alloc] init];
		
		[[NSNotificationCenter defaultCenter]
		 addObserver:self
		 selector:@selector(applicationWillTerminate:)
		 name:NSApplicationWillTerminateNotification
		 object:nil];
	}
	
	return self;
}

- (void)encodeRestorableStateWithCoder:(NSCoder *)coder
{
    [super encodeRestorableStateWithCoder:coder];
	
	[coder encodeObject:self.addressTextField.stringValue forKey:ZGDebuggerAddressField];
	[coder encodeObject:[self.runningApplicationsPopUpButton.selectedItem.representedObject name] forKey:ZGDebuggerProcessName];
}

- (void)restoreStateWithCoder:(NSCoder *)coder
{
	[super restoreStateWithCoder:coder];
	
	NSString *addressField = [coder decodeObjectForKey:ZGDebuggerAddressField];
	if (addressField)
	{
		self.addressTextField.stringValue = addressField;
	}
	
	self.desiredProcessName = [coder decodeObjectForKey:ZGDebuggerProcessName];
	
	[self updateRunningProcesses];
	
	[self windowDidShow:nil];
}

- (void)windowDidLoad
{
    [super windowDidLoad];
	
	[self setWindowAttributesWithIdentifier:ZGDebuggerIdentifier];
	
	[self setupProcessListNotificationsAndPopUpButton];
	
	[self.instructionsTableView registerForDraggedTypes:@[ZGVariablePboardType]];
}

- (void)windowDidAppearForFirstTime:(id)sender
{
	if (!sender)
	{
		[self readMemory:nil];
	}
	
	[self toggleBacktraceView:NSOffState];
	
	// ATOS_PATH may not exist if user is on SL unlesss he has developer tools installed, it should if user is on ML. Not sure about Lion.
	if (![[NSUserDefaults standardUserDefaults] boolForKey:ZG_SHOWED_ATOS_WARNING] && ![[NSFileManager defaultManager] fileExistsAtPath:ATOS_PATH])
	{
		NSLog(@"ERROR: %@ was not found.. Failed to retrieve debug symbols", ATOS_PATH);
		
		NSRunAlertPanel(@"Debug Symbols won't be Retrieved", @"In order to retrieve debug symbols, you may have to install the Xcode developer tools, which includes the atos tool that is needed.", @"OK", nil, nil, nil);
		
		[[NSUserDefaults standardUserDefaults] setBool:YES forKey:ZG_SHOWED_ATOS_WARNING];
	}
}

#pragma mark Current Process Changed

- (void)currentProcessChanged
{
	if (self.currentBreakPoint)
	{
		[self toggleBacktraceView:NSOnState];
		[self updateRegisters];
		[self.backtraceController updateBacktraceWithBasePointer:self.registersController.basePointer instructionPointer:self.registersController.programCounter inProcess:self.currentProcess];
		
		[self jumpToMemoryAddress:self.registersController.programCounter];
	}
	else
	{
		[self toggleBacktraceView:NSOffState];
		[self readMemory:nil];
	}
}

#pragma mark Split Views

- (CGFloat)splitView:(NSSplitView *)splitView constrainMinCoordinate:(CGFloat)proposedMinimumPosition ofSubviewAt:(NSInteger)dividerIndex
{
	return proposedMinimumPosition + 60;
}

- (BOOL)splitView:(NSSplitView *)splitView canCollapseSubview:(NSView *)subview
{
	if ([splitView.subviews objectAtIndex:1] == subview)
	{
		return YES;
	}
	
	return NO;
}

- (BOOL)splitView:(NSSplitView *)splitView shouldHideDividerAtIndex:(NSInteger)dividerIndex
{
	return (self.currentBreakPoint == nil);
}

// For collapsing and uncollapsing, useful info: http://manicwave.com/blog/2009/12/31/unraveling-the-mysteries-of-nssplitview-part-2/
- (void)uncollapseBottomSubview
{
	NSView *topSubview = [self.splitView.subviews objectAtIndex:0];
	NSView *bottomSubview = [self.splitView.subviews objectAtIndex:1];
	
	[bottomSubview setHidden:NO];
	
	NSRect topFrame = topSubview.frame;
	NSRect bottomFrame = bottomSubview.frame;
	
	topFrame.size.height = topFrame.size.height - bottomFrame.size.height - self.splitView.dividerThickness;
	bottomFrame.origin.y = topFrame.size.height + self.splitView.dividerThickness;
	
	topSubview.frameSize = topFrame.size;
	bottomSubview.frame = bottomFrame;
	[self.splitView display];
}

- (void)collapseBottomSubview
{
	NSView *topSubview = [self.splitView.subviews objectAtIndex:0];
	NSView *bottomSubview = [self.splitView.subviews objectAtIndex:1];
	
	[bottomSubview setHidden:YES];
	[topSubview setFrameSize:NSMakeSize(topSubview.frame.size.width, self.splitView.frame.size.height)];
	[self.splitView display];
}

- (void)toggleBacktraceView:(NSCellStateValue)state
{	
	switch (state)
	{
		case NSOnState:
			if ([self.splitView isSubviewCollapsed:[self.splitView.subviews objectAtIndex:1]])
			{
				[self uncollapseBottomSubview];
			}
			break;
		case NSOffState:
			if (![self.splitView isSubviewCollapsed:[self.splitView.subviews objectAtIndex:1]])
			{
				[self.undoManager removeAllActionsWithTarget:self.registersController];
				[self collapseBottomSubview];
			}
			break;
		default:
			break;
	}
}

#pragma mark Symbols

- (void)updateSymbolsForInstructions:(NSArray *)instructions
{
	[self updateSymbolsForInstructions:instructions asynchronously:NO completionHandler:^{}];
}

- (void)updateSymbolsForInstructions:(NSArray *)instructions asynchronously:(BOOL)isAsynchronous completionHandler:(void (^)(void))completionHandler
{
	static BOOL shouldFindSymbols = YES;
	void (^updateSymbolsBlock)(void) = ^{
		if (shouldFindSymbols && [[NSFileManager defaultManager] fileExistsAtPath:ATOS_PATH])
		{
			NSTask *atosTask = [[NSTask alloc] init];
			[atosTask setLaunchPath:ATOS_PATH];
			[atosTask setArguments:@[@"-p", [NSString stringWithFormat:@"%d", self.currentProcess.processID]]];
			
			NSPipe *inputPipe = [NSPipe pipe];
			[atosTask setStandardInput:inputPipe];
			
			NSPipe *outputPipe = [NSPipe pipe];
			[atosTask setStandardOutput:outputPipe];
			
			// Ignore error message saying that atos has RESTRICT section thus DYLD environment variables being ignored
			[atosTask setStandardError:[NSPipe pipe]];
			
			@try
			{
				[atosTask launch];
			}
			@catch (NSException *exception)
			{
				NSLog(@"Atos task failed: Name: %@, Reason: %@", exception.name, exception.reason);
				NSLog(@"Stopping atos from being called for this run...");
				shouldFindSymbols = NO;
				return;
			}
			
			for (ZGInstruction *instruction in instructions)
			{
				[[inputPipe fileHandleForWriting] writeData:[[instruction.variable.addressStringValue stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
			}
			
			[[inputPipe fileHandleForWriting] closeFile];
			
			NSData *data = [[outputPipe fileHandleForReading] readDataToEndOfFile];
			if (data)
			{
				NSUInteger instructionIndex = 0;
				NSString *contents = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
				for (NSString *line in [contents componentsSeparatedByString:@"\n"])
				{
					if ([line length] > 0 && ![line isEqualToString:@""] && ![line isEqualToString:@"\n"] && instructionIndex < instructions.count)
					{
						ZGInstruction *instruction = [instructions objectAtIndex:instructionIndex];
						
						if (isAsynchronous)
						{
							dispatch_async(dispatch_get_main_queue(), ^{
								instruction.symbols = line;
							});
						}
						else
						{
							instruction.symbols = line;
						}
					}
					
					instructionIndex++;
				}
			}
		}
	};
	
	if (isAsynchronous)
	{
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			updateSymbolsBlock();
			
			dispatch_async(dispatch_get_main_queue(), ^{
				completionHandler();
			});
		});
	}
	else
	{
		updateSymbolsBlock();
	}
}

- (BOOL)shouldUpdateSymbolsForInstructions:(NSArray *)instructions
{
	BOOL shouldUpdateSymbols = NO;
	
	for (ZGInstruction *instruction in instructions)
	{
		if (!instruction.symbols)
		{
			shouldUpdateSymbols = YES;
			break;
		}
	}
	
	return shouldUpdateSymbols;
}

#pragma mark Disassembling

- (NSData *)readDataWithTaskPort:(ZGMemoryMap)taskPort address:(ZGMemoryAddress)address size:(ZGMemorySize)size
{
	void *originalBytes = NULL;
	if (!ZGReadBytes(taskPort, address, &originalBytes, &size))
	{
		NSLog(@"Failed reading data in debugger..");
		return nil;
	}
	
	NSArray *breakPoints = [[[ZGAppController sharedController] breakPointController] breakPoints];
	void *newBytes = malloc(size);
	memcpy(newBytes, originalBytes, size);
	
	ZGFreeBytes(taskPort, originalBytes, size);
	
	for (ZGBreakPoint *breakPoint in breakPoints)
	{
		if (breakPoint.type == ZGBreakPointInstruction && breakPoint.task == taskPort && breakPoint.variable.address >= address && breakPoint.variable.address < address + size)
		{
			memcpy(newBytes + (breakPoint.variable.address - address), breakPoint.variable.value, sizeof(uint8_t));
		}
	}
	
	return [NSData dataWithBytesNoCopy:newBytes length:size];
}

- (ZGDisassemblerObject *)disassemblerObjectWithTaskPort:(ZGMemoryMap)taskPort pointerSize:(ZGMemorySize)pointerSize address:(ZGMemoryAddress)address size:(ZGMemorySize)size
{
	ZGDisassemblerObject *newObject = nil;
	NSData *data = [self readDataWithTaskPort:taskPort address:address size:size];
	if (data != nil)
	{
		newObject = [[ZGDisassemblerObject alloc] initWithBytes:data.bytes address:address size:data.length pointerSize:pointerSize];
	}
	return newObject;
}

- (ZGInstruction *)findInstructionBeforeAddress:(ZGMemoryAddress)address inProcess:(ZGProcess *)process
{
	return [self findInstructionBeforeAddress:address inTaskPort:process.processTask pointerSize:process.pointerSize];
}

- (ZGInstruction *)findInstructionBeforeAddress:(ZGMemoryAddress)address inTaskPort:(ZGMemoryMap)taskPort pointerSize:(ZGMemorySize)pointerSize
{
	ZGInstruction *instruction = nil;
	
	NSArray *regions = ZGRegionsForProcessTask(taskPort);
	
	ZGRegion *targetRegion = [regions zgBinarySearchUsingBlock:(zg_binary_search_t)^(ZGRegion * __unsafe_unretained region) {
		if (region.address + region.size <= address)
		{
			return NSOrderedAscending;
		}
		else if (region.address > address)
		{
			return NSOrderedDescending;
		}
		else
		{
			return NSOrderedSame;
		}
	}];
	
	if (targetRegion != nil && address >= targetRegion.address && address <= targetRegion.address + targetRegion.size)
	{
		// Start an arbitrary number of bytes before our address and decode the instructions
		// Eventually they will converge into correct offsets
		// So retrieve the offset and size to the last instruction while decoding
		// We do this instead of starting at region.address due to this leading to better performance
		
		ZGMemoryAddress startAddress = address - 1024;
		if (startAddress < targetRegion.address)
		{
			startAddress = targetRegion.address;
		}
		
		ZGMemorySize size = address - startAddress;
		// Read in more bytes to ensure we return the whole instruction
		ZGMemorySize readSize = size + 30;
		if (startAddress + readSize > targetRegion.address + targetRegion.size)
		{
			readSize = targetRegion.address + targetRegion.size - startAddress;
		}
		
		ZGDisassemblerObject *disassemblerObject = [self disassemblerObjectWithTaskPort:taskPort pointerSize:pointerSize address:startAddress size:readSize];
		if (disassemblerObject != nil)
		{
			__block ZGMemoryAddress memoryOffset = 0;
			__block ZGMemorySize memorySize = 0;
			__block NSString *instructionText = nil;
			__block ud_mnemonic_code_t instructionMnemonic = 0;
			
			[disassemblerObject enumerateWithBlock:^(ZGMemoryAddress instructionAddress, ZGMemorySize instructionSize, ud_mnemonic_code_t mnemonic, NSString *disassembledText, BOOL *stop) {
				if ((instructionAddress - startAddress) + instructionSize >= size)
				{
					memoryOffset = instructionAddress - startAddress;
					memorySize = instructionSize;
					instructionText = disassembledText;
					instructionMnemonic = mnemonic;
					*stop = YES;
				}
			}];
			
			instruction = [[ZGInstruction alloc] init];
			instruction.text = instructionText;
			instruction.mnemonic = instructionMnemonic;
			ZGVariable *variable = [[ZGVariable alloc] initWithValue:disassemblerObject.bytes + memoryOffset size:memorySize address:startAddress + memoryOffset type:ZGByteArray qualifier:0 pointerSize:pointerSize name:instruction.text enabled:NO];
			instruction.variable = variable;
		}
	}
	
	return instruction;
}

- (void)updateInstructionValues
{
	// Check to see if anything in the window needs to be updated
	NSRange visibleRowsRange = [self.instructionsTableView rowsInRect:self.instructionsTableView.visibleRect];
	if (visibleRowsRange.location + visibleRowsRange.length <= self.instructions.count)
	{
		__block ZGMemoryAddress regionAddress = 0x0;
		__block ZGMemorySize regionSize = 0x0;
		__block BOOL foundRegion = NO;
		
		__block BOOL needsToUpdateWindow = NO;
		[[self.instructions subarrayWithRange:visibleRowsRange] enumerateObjectsUsingBlock:^(ZGInstruction *instruction, NSUInteger index, BOOL *stop)
		 {
			 void *bytes = NULL;
			 ZGMemorySize size = instruction.variable.size;
			 if (ZGReadBytes(self.currentProcess.processTask, instruction.variable.address, &bytes, &size))
			 {
				 if (memcmp(bytes, instruction.variable.value, size) != 0)
				 {
					 // Ignore trivial breakpoint changes
					 BOOL foundBreakPoint = NO;
					 if (*(uint8_t *)bytes == INSTRUCTION_BREAKPOINT_OPCODE && (size == sizeof(uint8_t) || memcmp(bytes+sizeof(uint8_t), instruction.variable.value+sizeof(uint8_t), size-sizeof(uint8_t)) == 0))
					 {
						 for (ZGBreakPoint *breakPoint in [[[ZGAppController sharedController] breakPointController] breakPoints])
						 {
							 if (breakPoint.type == ZGBreakPointInstruction && breakPoint.variable.address == instruction.variable.address && *(uint8_t *)breakPoint.variable.value == *(uint8_t *)instruction.variable.value)
							 {
								 foundBreakPoint = YES;
								 break;
							 }
						 }
					 }
					 
					 if (!foundBreakPoint)
					 {
						 // Find the region our instruction is in
						 vm_region_basic_info_data_64_t unusedInfo;
						 regionAddress = instruction.variable.address;
						 regionSize = instruction.variable.size;
						 foundRegion = ZGRegionInfo(self.currentProcess.processTask, &regionAddress, &regionSize, &unusedInfo);
						 needsToUpdateWindow = YES;
						 *stop = YES;
					 }
				 }
				 
				 ZGFreeBytes(self.currentProcess.processTask, bytes, size);
			 }
		 }];
		
		if (needsToUpdateWindow)
		{
			// Set up a limit on low and high boundaries so that we don't overlap regions
			// note this is not perfect, in particular, if two regions are visible (say in a branch island after a code injection) this needsToUpdateWindow branch may be called frequently afterwards,
			// until the user scrolls around a bit, or so. This is better than the disassembler completely messing up on the instructions though
			BOOL foundRegionLowIndex = NO;
			NSUInteger regionLowIndex = 0;
			NSUInteger regionHighIndex = 0;
			for (NSUInteger instructionIndex = visibleRowsRange.location; instructionIndex < visibleRowsRange.location + visibleRowsRange.length; instructionIndex++)
			{
				ZGInstruction *instruction = [self.instructions objectAtIndex:instructionIndex];
				if (instruction.variable.address >= regionAddress && instruction.variable.address + instruction.variable.size <= regionAddress + regionSize)
				{
					if (!foundRegionLowIndex)
					{
						foundRegionLowIndex = YES;
						regionLowIndex = instructionIndex;
					}
					
					regionHighIndex = instructionIndex + 1;
				}
				
				instructionIndex++;
			}
			
			// Find a [start, end) range that we are allowed to remove from the table and insert in again with new instructions
			// Pick start and end such that they are aligned with the assembly instructions
			
			NSUInteger startRow = visibleRowsRange.location;
			
			do
			{
				if (startRow == 0) break;
				
				ZGInstruction *instruction = [self.instructions objectAtIndex:startRow];
				ZGInstruction *searchedInstruction = [self findInstructionBeforeAddress:instruction.variable.address inProcess:self.currentProcess];
				
				startRow--;
				
				if (searchedInstruction.variable.address + searchedInstruction.variable.size == instruction.variable.address)
				{
					break;
				}
			}
			while (YES);
			
			startRow = MAX(startRow, regionLowIndex);
			
			ZGInstruction *startInstruction = [self.instructions objectAtIndex:startRow];
			ZGMemoryAddress startAddress = startInstruction.variable.address;
			
			// Extend past first row if necessary
			if (startRow == 0)
			{
				ZGInstruction *searchedInstruction = [self findInstructionBeforeAddress:startInstruction.variable.address inProcess:self.currentProcess];
				if (searchedInstruction.variable.address + searchedInstruction.variable.size != startAddress)
				{
					startAddress = searchedInstruction.variable.address;
				}
			}
			
			NSUInteger endRow = visibleRowsRange.location + visibleRowsRange.length - 1;
			
			do
			{
				if (endRow >= self.instructions.count) break;
				
				ZGInstruction *instruction = [self.instructions objectAtIndex:endRow];
				ZGInstruction *searchedInstruction = [self findInstructionBeforeAddress:instruction.variable.address + instruction.variable.size inProcess:self.currentProcess];
				
				endRow++;
				
				if (searchedInstruction.variable.address == instruction.variable.address)
				{
					break;
				}
			}
			while (YES);
			
			endRow = MIN(endRow, regionHighIndex);
			
			ZGInstruction *endInstruction = [self.instructions objectAtIndex:endRow-1];
			ZGMemoryAddress endAddress = endInstruction.variable.address + endInstruction.variable.size;
			
			// Extend past last row if necessary
			if (endRow >= self.instructions.count)
			{
				ZGInstruction *searchedInstruction = [self findInstructionBeforeAddress:endInstruction.variable.address + endInstruction.variable.size inProcess:self.currentProcess];
				if (endInstruction.variable.address != searchedInstruction.variable.address)
				{
					endAddress = searchedInstruction.variable.address + searchedInstruction.variable.size;
				}
			}
			
			ZGMemorySize size = endAddress - startAddress;
			
			ZGDisassemblerObject *disassemblerObject = [self disassemblerObjectWithTaskPort:self.currentProcess.processTask pointerSize:self.currentProcess.pointerSize address:startAddress size:size];
			if (disassemblerObject != nil)
			{
				NSMutableArray *instructionsToReplace = [[NSMutableArray alloc] init];
				
				[disassemblerObject enumerateWithBlock:^(ZGMemoryAddress instructionAddress, ZGMemorySize instructionSize, ud_mnemonic_code_t mnemonic, NSString *disassembledText, BOOL *stop)  {
					ZGInstruction *newInstruction = [[ZGInstruction alloc] init];
					newInstruction.text = disassembledText;
					newInstruction.variable = [[ZGVariable alloc] initWithValue:disassemblerObject.bytes + (instructionAddress - startAddress) size:instructionSize address:instructionAddress type:ZGByteArray qualifier:0 pointerSize:self.currentProcess.pointerSize name:newInstruction.text enabled:NO];
					newInstruction.mnemonic = mnemonic;
					
					[instructionsToReplace addObject:newInstruction];
				}];
				
				// Replace the visible instructions
				NSMutableArray *newInstructions = [[NSMutableArray alloc] initWithArray:self.instructions];
				[newInstructions replaceObjectsInRange:NSMakeRange(startRow, endRow - startRow) withObjectsFromArray:instructionsToReplace];
				self.instructions = [NSArray arrayWithArray:newInstructions];
				
				[self.instructionsTableView reloadData];
			}
		}
	}
}

- (void)updateInstructionSymbols
{
	static BOOL isUpdatingSymbols = NO;
	
	NSRange visibleRowsRange = [self.instructionsTableView rowsInRect:self.instructionsTableView.visibleRect];
	if (visibleRowsRange.location + visibleRowsRange.length <= self.instructions.count)
	{
		NSArray *instructions = [self.instructions subarrayWithRange:visibleRowsRange];
		if ([self shouldUpdateSymbolsForInstructions:instructions] && !isUpdatingSymbols)
		{
			isUpdatingSymbols = YES;
			[self updateSymbolsForInstructions:instructions asynchronously:YES completionHandler:^{
				[self.instructionsTableView reloadData];
				isUpdatingSymbols = NO;
			}];
		}
	}
}

#define DESIRED_BYTES_TO_ADD_OFFSET 10000

- (void)addMoreInstructionsBeforeFirstRow
{
	ZGInstruction *endInstruction = [self.instructions objectAtIndex:0];
	ZGInstruction *startInstruction = nil;
	NSUInteger bytesBehind = DESIRED_BYTES_TO_ADD_OFFSET;
	while (!startInstruction && bytesBehind > 0)
	{
		startInstruction = [self findInstructionBeforeAddress:endInstruction.variable.address - bytesBehind inProcess:self.currentProcess];
		bytesBehind /= 2;
	}
	
	if (startInstruction)
	{
		ZGMemorySize size = endInstruction.variable.address - startInstruction.variable.address;
		
		NSMutableArray *instructionsToAdd = [[NSMutableArray alloc] init];
		
		ZGDisassemblerObject *disassemblerObject = [self disassemblerObjectWithTaskPort:self.currentProcess.processTask pointerSize:self.currentProcess.pointerSize address:startInstruction.variable size:size];
		
		if (disassemblerObject != nil)
		{
			[disassemblerObject enumerateWithBlock:^(ZGMemoryAddress instructionAddress, ZGMemorySize instructionSize, ud_mnemonic_code_t mnemonic, NSString *disassembledText, BOOL *stop)  {
				ZGInstruction *newInstruction = [[ZGInstruction alloc] init];
				newInstruction.text = disassembledText;
				newInstruction.variable = [[ZGVariable alloc] initWithValue:disassemblerObject.bytes + (instructionAddress - startInstruction.variable.address) size:instructionSize address:instructionAddress type:ZGByteArray qualifier:0 pointerSize:self.currentProcess.pointerSize name:newInstruction.text enabled:NO];
				newInstruction.mnemonic = mnemonic;
				
				[instructionsToAdd addObject:newInstruction];
			}];
			
			NSUInteger numberOfInstructionsAdded = instructionsToAdd.count;
			NSRange visibleRowsRange = [self.instructionsTableView rowsInRect:self.instructionsTableView.visibleRect];
			
			[instructionsToAdd addObjectsFromArray:self.instructions];
			self.instructions = [NSArray arrayWithArray:instructionsToAdd];
			
			NSInteger previousSelectedRow = [self.instructionsTableView selectedRow];
			[self.instructionsTableView noteNumberOfRowsChanged];
			
			[self.instructionsTableView scrollRowToVisible:MIN(numberOfInstructionsAdded + visibleRowsRange.length - 1, self.instructions.count)];
			
			if (previousSelectedRow >= 0)
			{
				[self.instructionsTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:previousSelectedRow + numberOfInstructionsAdded] byExtendingSelection:NO];
			}
		}
	}
}

- (void)addMoreInstructionsAfterLastRow
{
	ZGInstruction *lastInstruction = self.instructions.lastObject;
	ZGInstruction *startInstruction = [self findInstructionBeforeAddress:(lastInstruction.variable.address + lastInstruction.variable.size + 1) inProcess:self.currentProcess];
	if (startInstruction)
	{
		ZGInstruction *endInstruction = nil;
		NSUInteger bytesAhead = DESIRED_BYTES_TO_ADD_OFFSET;
		while (!endInstruction && bytesAhead > 0)
		{
			endInstruction = [self findInstructionBeforeAddress:(startInstruction.variable.address + startInstruction.variable.size + bytesAhead) inProcess:self.currentProcess];
			bytesAhead /= 2;
		}
		
		if (endInstruction)
		{
			ZGMemorySize size = endInstruction.variable.address - startInstruction.variable.address;
			
			NSMutableArray *instructionsToAdd = [[NSMutableArray alloc] init];
			
			ZGDisassemblerObject *disassemblerObject = [self disassemblerObjectWithTaskPort:self.currentProcess.processTask pointerSize:self.currentProcess.pointerSize address:startInstruction.variable.address size:size];
			
			if (disassemblerObject != nil)
			{
				[disassemblerObject enumerateWithBlock:^(ZGMemoryAddress instructionAddress, ZGMemorySize instructionSize, ud_mnemonic_code_t mnemonic, NSString *disassembledText, BOOL *stop)  {
					ZGInstruction *newInstruction = [[ZGInstruction alloc] init];
					newInstruction.text = disassembledText;
					newInstruction.variable = [[ZGVariable alloc] initWithValue:disassemblerObject.bytes + (instructionAddress - startInstruction.variable.address) size:instructionSize address:instructionAddress type:ZGByteArray qualifier:0 pointerSize:self.currentProcess.pointerSize name:newInstruction.text enabled:NO];
					newInstruction.mnemonic = mnemonic;
					
					[instructionsToAdd addObject:newInstruction];
				}];
				
				NSMutableArray *appendedInstructions = [NSMutableArray arrayWithArray:self.instructions];
				[appendedInstructions addObjectsFromArray:instructionsToAdd];
				
				self.instructions = [NSArray arrayWithArray:appendedInstructions];
				
				[self.instructionsTableView noteNumberOfRowsChanged];
			}
		}
	}
}

- (void)updateInstructionsBeyondTableView
{
	NSRange visibleRowsRange = [self.instructionsTableView rowsInRect:self.instructionsTableView.visibleRect];
	if (visibleRowsRange.location == 0)
	{
		[self addMoreInstructionsBeforeFirstRow];
	}
	else if (visibleRowsRange.location + visibleRowsRange.length >= self.instructions.count)
	{
		[self addMoreInstructionsAfterLastRow];
	}
}

- (void)updateDisplayTimer:(NSTimer *)timer
{
	if (self.currentProcess.valid && self.instructionsTableView.editedRow == -1 && !self.disassembling && self.instructions.count > 0)
	{
		[self updateInstructionValues];
		[self updateInstructionSymbols];
		[self updateInstructionsBeyondTableView];
	}
}

- (IBAction)stopDisassembling:(id)sender
{
	self.disassembling = NO;
	[self.stopButton setEnabled:NO];
}

- (void)updateDisassemblerWithAddress:(ZGMemoryAddress)address size:(ZGMemorySize)theSize selectionAddress:(ZGMemoryAddress)selectionAddress
{
	[self.dissemblyProgressIndicator setMinValue:0];
	[self.dissemblyProgressIndicator setMaxValue:theSize];
	[self.dissemblyProgressIndicator setDoubleValue:0];
	[self.dissemblyProgressIndicator setHidden:NO];
	[self.addressTextField setEnabled:NO];
	[self.runningApplicationsPopUpButton setEnabled:NO];
	[self.stopButton setEnabled:YES];
	[self.stopButton setHidden:NO];
	
	[self prepareNavigation];
	
	self.instructions = @[];
	[self.instructionsTableView reloadData];
	
	self.currentMemoryAddress = address;
	self.currentMemorySize = 0;
	
	self.disassembling = YES;
	
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		ZGMemorySize size = theSize;
		ZGDisassemblerObject *disassemblerObject = [self disassemblerObjectWithTaskPort:self.currentProcess.processTask pointerSize:self.currentProcess.pointerSize address:address size:size];
		
		if (disassemblerObject != nil)
		{
			__block NSMutableArray *newInstructions = [[NSMutableArray alloc] init];
			
			// We add instructions to table in batches. First time 1000 variables will be added, 2nd time 1000*2, third time 1000*2*2, etc.
			__block NSUInteger thresholdCount = 1000;
			
			__block NSUInteger totalInstructionCount = 0;
			
			__block NSUInteger selectionRow = 0;
			
			// Block for adding a batch of instructions which will be used for later
			void (^addBatchOfInstructions)(void) = ^{
				NSArray *currentBatch = newInstructions;
				
				dispatch_async(dispatch_get_main_queue(), ^{
					NSMutableArray *appendedInstructions = [[NSMutableArray alloc] initWithArray:self.instructions];
					[appendedInstructions addObjectsFromArray:currentBatch];
					
					if (self.instructions.count == 0 && self.window.firstResponder != self.backtraceController.tableView)
					{
						[self.window makeFirstResponder:self.instructionsTableView];
					}
					self.instructions = [NSArray arrayWithArray:appendedInstructions];
					[self.instructionsTableView noteNumberOfRowsChanged];
					self.currentMemorySize = self.instructions.count;
				});
			};
			
			[disassemblerObject enumerateWithBlock:^(ZGMemoryAddress instructionAddress, ZGMemorySize instructionSize, ud_mnemonic_code_t mnemonic, NSString *disassembledText, BOOL *stop)  {
				ZGInstruction *instruction = [[ZGInstruction alloc] init];
				instruction.text = disassembledText;
				instruction.variable = [[ZGVariable alloc] initWithValue:disassemblerObject.bytes + (instructionAddress - address) size:instructionSize address:instructionAddress type:ZGByteArray qualifier:0 pointerSize:self.currentProcess.pointerSize name:instruction.text enabled:NO];
				instruction.mnemonic = mnemonic;
				
				[newInstructions addObject:instruction];
				
				dispatch_async(dispatch_get_main_queue(), ^{
					self.dissemblyProgressIndicator.doubleValue += instruction.variable.size;
				});
				
				if (selectionAddress >= instruction.variable.address && selectionAddress < instruction.variable.address + instruction.variable.size)
				{
					selectionRow = totalInstructionCount;
				}
				
				if (!self.disassembling)
				{
					*stop = YES;
				}
				else
				{
					totalInstructionCount++;
					
					if (totalInstructionCount >= thresholdCount)
					{
						addBatchOfInstructions();
						newInstructions = [[NSMutableArray alloc] init];
						thresholdCount *= 2;
					}
				}
			}];
			
			// Add the leftover batch
			addBatchOfInstructions();
			
			dispatch_async(dispatch_get_main_queue(), ^{
				[self scrollAndSelectRow:selectionRow];
				
				self.disassembling = NO;
				[self.dissemblyProgressIndicator setHidden:YES];
				[self.addressTextField setEnabled:YES];
				[self.runningApplicationsPopUpButton setEnabled:YES];
				[self.stopButton setHidden:YES];
				
				[self updateNavigationButtons];
			});
		}
	});
}

#pragma mark Handling Processes

- (void)processListChanged:(NSDictionary *)change
{
	NSArray *oldRunningProcesses = [change objectForKey:NSKeyValueChangeOldKey];
	if (oldRunningProcesses)
	{
		for (ZGRunningProcess *runningProcess in oldRunningProcesses)
		{
			[[[ZGAppController sharedController] breakPointController] removeObserver:self runningProcess:runningProcess];
			for (ZGBreakPoint *haltedBreakPoint in self.haltedBreakPoints)
			{
				if (haltedBreakPoint.process.processID == runningProcess.processIdentifier)
				{
					[self removeHaltedBreakPoint:haltedBreakPoint];
				}
			}
		}
	}
}

- (void)switchProcessMenuItemAndSelectAddress:(ZGMemoryAddress)address
{
	if ([self.runningApplicationsPopUpButton.selectedItem.representedObject processID] != self.currentProcess.processID)
	{
		self.addressTextField.stringValue = [NSString stringWithFormat:@"0x%llX", address];
		[self switchProcess];
	}
}

- (IBAction)runningApplicationsPopUpButton:(id)sender
{
	[self switchProcessMenuItemAndSelectAddress:0x0];
}

#pragma mark Changing disassembler view

- (BOOL)canEnableNavigationButtons
{
	return !self.disassembling && [super canEnableNavigationButtons];
}

- (IBAction)goToCallAddress:(id)sender
{
	ZGInstruction *selectedInstruction = [[self selectedInstructions] objectAtIndex:0];
	[self jumpToMemoryAddress:selectedInstruction.callAddress];
}

- (void)prepareNavigation
{
	if (self.instructions.count > 0)
	{
		NSRange visibleRowsRange = [self.instructionsTableView rowsInRect:self.instructionsTableView.visibleRect];
		
		if (self.instructionsTableView.selectedRowIndexes.count > 0 && self.instructionsTableView.selectedRowIndexes.firstIndex >= visibleRowsRange.location && self.instructionsTableView.selectedRowIndexes.firstIndex < visibleRowsRange.location + visibleRowsRange.length && self.instructionsTableView.selectedRowIndexes.firstIndex < self.instructions.count)
		{
			ZGInstruction *selectedInstruction = [self.instructions objectAtIndex:self.instructionsTableView.selectedRowIndexes.firstIndex];
			[[self.navigationManager prepareWithInvocationTarget:self] jumpToMemoryAddress:selectedInstruction.variable.address];
		}
		else
		{
			NSUInteger centeredInstructionIndex = visibleRowsRange.location + visibleRowsRange.length / 2;
			if (centeredInstructionIndex < self.instructions.count)
			{
				ZGInstruction *centeredInstruction = [self.instructions objectAtIndex:centeredInstructionIndex];
				[[self.navigationManager prepareWithInvocationTarget:self] jumpToMemoryAddress:centeredInstruction.variable.address];
			}
		}
	}
}

- (IBAction)readMemory:(id)sender
{
	BOOL success = NO;
	
	if (!self.currentProcess.valid || ![self.currentProcess hasGrantedAccess])
	{
		goto END_DEBUGGER_CHANGE;
	}
	
	// create scope block to allow for goto
	{
		NSString *calculatedMemoryAddressExpression = [ZGCalculator evaluateExpression:self.addressTextField.stringValue];
		
		ZGMemoryAddress calculatedMemoryAddress = 0;
		
		if (isValidNumber(calculatedMemoryAddressExpression))
		{
			calculatedMemoryAddress = memoryAddressFromExpression(calculatedMemoryAddressExpression);
		}
		
		// See if the instruction is already in the table, if so, just go to it
		ZGInstruction *foundInstructionInTable = [self findInstructionInTableAtAddress:calculatedMemoryAddress];
		if (foundInstructionInTable)
		{
			[self prepareNavigation];
			[self scrollAndSelectRow:[self.instructions indexOfObject:foundInstructionInTable]];
			if (self.window.firstResponder != self.backtraceController.tableView)
			{
				[self.window makeFirstResponder:self.instructionsTableView];
			}
			
			[self updateNavigationButtons];
			
			success = YES;
			goto END_DEBUGGER_CHANGE;
		}
		
		NSArray *memoryRegions = ZGRegionsForProcessTask(self.currentProcess.processTask);
		if (memoryRegions.count == 0)
		{
			goto END_DEBUGGER_CHANGE;
		}
		
		ZGRegion *chosenRegion = nil;
		for (ZGRegion *region in memoryRegions)
		{
			if ((region.protection & VM_PROT_READ) && (calculatedMemoryAddress <= 0 || (calculatedMemoryAddress >= region.address && calculatedMemoryAddress < region.address + region.size)))
			{
				chosenRegion = region;
				break;
			}
		}
		
		if (!chosenRegion)
		{
			goto END_DEBUGGER_CHANGE;
		}
		
		if (calculatedMemoryAddress <= 0)
		{
			calculatedMemoryAddress = chosenRegion.address;
			[self.addressTextField setStringValue:[NSString stringWithFormat:@"0x%llX", calculatedMemoryAddress]];
		}
		
		// Disassemble within a range from +- WINDOW_SIZE from selection address
		const NSUInteger WINDOW_SIZE = 50000;
		
		ZGMemoryAddress lowBoundAddress = calculatedMemoryAddress - WINDOW_SIZE;
		if (lowBoundAddress <= chosenRegion.address)
		{
			lowBoundAddress = chosenRegion.address;
		}
		else
		{
			lowBoundAddress = [self findInstructionBeforeAddress:lowBoundAddress inProcess:self.currentProcess].variable.address;
			if (lowBoundAddress < chosenRegion.address)
			{
				lowBoundAddress = chosenRegion.address;
			}
		}
		
		ZGMemoryAddress highBoundAddress = calculatedMemoryAddress + WINDOW_SIZE;
		if (highBoundAddress >= chosenRegion.address + chosenRegion.size)
		{
			highBoundAddress = chosenRegion.address + chosenRegion.size;
		}
		else
		{
			highBoundAddress = [self findInstructionBeforeAddress:highBoundAddress inProcess:self.currentProcess].variable.address;
			if (highBoundAddress <= chosenRegion.address || highBoundAddress > chosenRegion.address + chosenRegion.size)
			{
				highBoundAddress = chosenRegion.address + chosenRegion.size;
			}
		}
		
		[self.undoManager removeAllActions];
		[self updateDisassemblerWithAddress:lowBoundAddress size:highBoundAddress - lowBoundAddress selectionAddress:calculatedMemoryAddress];
		
		success = YES;
	}
	
END_DEBUGGER_CHANGE:
	if (!success)
	{
		// clear data
		self.instructions = [NSArray array];
		[self.instructionsTableView reloadData];
	}
}

#pragma mark Useful methods for the world

- (NSIndexSet *)selectedInstructionIndexes
{
	NSIndexSet *tableIndexSet = self.instructionsTableView.selectedRowIndexes;
	NSInteger clickedRow = self.instructionsTableView.clickedRow;
	
	return (clickedRow != -1 && ![tableIndexSet containsIndex:clickedRow]) ? [NSIndexSet indexSetWithIndex:clickedRow] : tableIndexSet;
}

- (NSArray *)selectedInstructions
{
	return [self.instructions objectsAtIndexes:[self selectedInstructionIndexes]];
}

- (void)jumpToMemoryAddress:(ZGMemoryAddress)address
{
	[self jumpToMemoryAddress:address inProcess:self.currentProcess];
}

- (void)jumpToMemoryAddress:(ZGMemoryAddress)address inProcess:(ZGProcess *)requestedProcess
{
	NSMenuItem *targetMenuItem = nil;
	for (NSMenuItem *menuItem in self.runningApplicationsPopUpButton.menu.itemArray)
	{
		ZGProcess *process = menuItem.representedObject;
		if ([process processID] == requestedProcess.processID)
		{
			targetMenuItem = menuItem;
			break;
		}
	}
	
	if (targetMenuItem)
	{
		self.addressTextField.stringValue = [NSString stringWithFormat:@"0x%llX", address];
		
		if ([targetMenuItem.representedObject processID] != self.currentProcess.processID)
		{
			[self.runningApplicationsPopUpButton selectItem:targetMenuItem];
			
			self.instructions = @[];
			[self.instructionsTableView reloadData];
			
			[self switchProcessMenuItemAndSelectAddress:address];
		}
		else
		{
			[self readMemory:nil];
		}
	}
	else
	{
		NSLog(@"Could not find target process!");
	}
}

- (BOOL)validateUserInterfaceItem:(NSMenuItem *)menuItem
{
	if (menuItem.action == @selector(nopVariables:))
	{
		[menuItem setTitle:[NSString stringWithFormat:@"NOP Instruction%@", self.selectedInstructions.count == 1 ? @"" : @"s"]];
		if (self.selectedInstructions.count == 0 || !self.currentProcess.valid || self.instructionsTableView.editedRow != -1 || self.disassembling)
		{
			return NO;
		}
	}
	else if (menuItem.action == @selector(copy:))
	{
		if (self.selectedInstructions.count == 0)
		{
			return NO;
		}
	}
	else if (menuItem.action == @selector(copyAddress:))
	{
		if (self.selectedInstructions.count != 1)
		{
			return NO;
		}
	}
	else if (menuItem.action == @selector(continueExecution:) || menuItem.action == @selector(stepInto:))
	{
		if (!self.currentBreakPoint || self.disassembling)
		{
			return NO;
		}
	}
	else if (menuItem.action == @selector(stepOver:))
	{
		if (!self.currentBreakPoint || self.disassembling)
		{
			return NO;
		}
		
		ZGInstruction *currentInstruction = [self findInstructionBeforeAddress:self.registersController.programCounter + 1 inProcess:self.currentProcess];
		if (!currentInstruction)
		{
			return NO;
		}
		
		if ([currentInstruction isCallMnemonic])
		{
			ZGInstruction *nextInstruction = [self findInstructionBeforeAddress:currentInstruction.variable.address + currentInstruction.variable.size + 1 inProcess:self.currentProcess];
			if (!nextInstruction)
			{
				return NO;
			}
		}
	}
	else if (menuItem.action == @selector(stepOut:))
	{
		if (!self.currentBreakPoint || self.disassembling)
		{
			return NO;
		}
		
		if (self.backtraceController.instructions.count <= 1 || self.backtraceController.basePointers.count <= 1)
		{
			return NO;
		}
		
		ZGInstruction *outterInstruction = [self.backtraceController.instructions objectAtIndex:1];
		ZGInstruction *returnInstruction = [self findInstructionBeforeAddress:outterInstruction.variable.address + outterInstruction.variable.size + 1 inProcess:self.currentProcess];
		
		if (!returnInstruction)
		{
			return NO;
		}
	}
	else if (menuItem.action == @selector(toggleBreakPoints:))
	{
		if (self.disassembling || self.selectedInstructions.count == 0)
		{
			return NO;
		}
		
		BOOL shouldValidate = YES;
		BOOL isBreakPoint = [self isBreakPointAtInstruction:[self.selectedInstructions objectAtIndex:0]];
		BOOL didSkipFirstInstruction = NO;
		for (ZGInstruction *instruction in self.selectedInstructions)
		{
			if (!didSkipFirstInstruction)
			{
				didSkipFirstInstruction = YES;
			}
			else
			{
				if ([self isBreakPointAtInstruction:instruction] != isBreakPoint)
				{
					shouldValidate = NO;
					break;
				}
			}
		}
		
		[menuItem setTitle:[NSString stringWithFormat:@"%@ Breakpoint%@", isBreakPoint ? @"Remove" : @"Add", self.selectedInstructions.count != 1 ? @"s" : @""]];
		
		return shouldValidate;
	}
	else if (menuItem.action == @selector(removeAllBreakPoints:))
	{
		if (self.disassembling)
		{
			return NO;
		}
		
		BOOL shouldValidate = NO;
		
		for (ZGBreakPoint *breakPoint in [[[ZGAppController sharedController] breakPointController] breakPoints])
		{
			if (breakPoint.delegate == self)
			{
				shouldValidate = YES;
				break;
			}
		}
		
		return shouldValidate;
	}
	else if (menuItem.action == @selector(jump:))
	{
		if (self.disassembling || !self.currentBreakPoint || self.selectedInstructions.count != 1)
		{
			return NO;
		}
	}
	else if (menuItem.action == @selector(goToCallAddress:))
	{
		if (self.disassembling || !self.currentProcess.valid)
		{
			return NO;
		}
		
		if (self.selectedInstructions.count != 1)
		{
			return NO;
		}
		
		ZGInstruction *selectedInstruction = [self.selectedInstructions objectAtIndex:0];
		if (!selectedInstruction.isCallMnemonic)
		{
			return NO;
		}
	}
	else if (menuItem.action == @selector(showMemoryViewer:))
	{
		if ([[self selectedInstructions] count] == 0)
		{
			return NO;
		}
	}
	else if (menuItem.action == @selector(requestCodeInjection:))
	{
		if ([[self selectedInstructions] count] != 1)
		{
			return NO;
		}
	}
	
	return [super validateUserInterfaceItem:menuItem];
}

- (IBAction)copy:(id)sender
{
	NSMutableArray *descriptionComponents = [[NSMutableArray alloc] init];
	NSMutableArray *variablesArray = [[NSMutableArray alloc] init];
	
	for (ZGInstruction *instruction in self.selectedInstructions)
	{
		[descriptionComponents addObject:[@[instruction.variable.addressStringValue, instruction.text, instruction.variable.stringValue] componentsJoinedByString:@"\t"]];
		[variablesArray addObject:instruction.variable];
	}
	
	[[NSPasteboard generalPasteboard] declareTypes:@[NSStringPboardType, ZGVariablePboardType] owner:self];
	[[NSPasteboard generalPasteboard] setString:[descriptionComponents componentsJoinedByString:@"\n"] forType:NSStringPboardType];
	[[NSPasteboard generalPasteboard] setData:[NSKeyedArchiver archivedDataWithRootObject:variablesArray] forType:ZGVariablePboardType];
}

- (IBAction)copyAddress:(id)sender
{
	ZGInstruction *selectedInstruction = [self.selectedInstructions objectAtIndex:0];
	[[NSPasteboard generalPasteboard] declareTypes:@[NSStringPboardType] owner:self];
	[[NSPasteboard generalPasteboard] setString:selectedInstruction.variable.addressStringValue	forType:NSStringPboardType];
}

- (void)scrollAndSelectRow:(NSUInteger)selectionRow
{
	// Scroll such that the selected row is centered
	[self.instructionsTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:selectionRow] byExtendingSelection:NO];
	NSRange visibleRowsRange = [self.instructionsTableView rowsInRect:self.instructionsTableView.visibleRect];
	if (visibleRowsRange.location + visibleRowsRange.length / 2 < selectionRow)
	{
		[self.instructionsTableView scrollRowToVisible:MIN(selectionRow + visibleRowsRange.length / 2, self.instructions.count-1)];
	}
	else if (visibleRowsRange.location + visibleRowsRange.length / 2 > selectionRow)
	{
		// Make sure we don't go below 0 in unsigned arithmetic
		if (visibleRowsRange.length / 2 > selectionRow)
		{
			[self.instructionsTableView scrollRowToVisible:0];
		}
		else
		{
			[self.instructionsTableView scrollRowToVisible:selectionRow - visibleRowsRange.length / 2];
		}
	}
}

#pragma mark TableView Methods

- (BOOL)tableView:(NSTableView *)tableView writeRowsWithIndexes:(NSIndexSet *)rowIndexes toPasteboard:(NSPasteboard *)pboard
{
	NSArray *variables = [[self.instructions objectsAtIndexes:rowIndexes] valueForKey:@"variable"];
	return [pboard setData:[NSKeyedArchiver archivedDataWithRootObject:variables] forType:ZGVariablePboardType];
}

- (BOOL)selectionShouldChangeInTableView:(NSTableView *)aTableView
{
	if (self.shouldIgnoreTableViewSelectionChange)
	{
		self.shouldIgnoreTableViewSelectionChange = NO;
		return NO;
	}
	
	return YES;
}

- (BOOL)isBreakPointAtInstruction:(ZGInstruction *)instruction
{
	BOOL answer = NO;
	
	for (ZGBreakPoint *breakPoint in [[[ZGAppController sharedController] breakPointController] breakPoints])
	{
		if (breakPoint.type == ZGBreakPointInstruction && breakPoint.task == self.currentProcess.processTask && breakPoint.variable.address == instruction.variable.address && !breakPoint.hidden)
		{
			answer = YES;
			break;
		}
	}
	
	return answer;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	return self.instructions.count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	id result = nil;
	if (rowIndex >= 0 && (NSUInteger)rowIndex < self.instructions.count)
	{
		ZGInstruction *instruction = [self.instructions objectAtIndex:rowIndex];
		if ([tableColumn.identifier isEqualToString:@"address"])
		{
			result = instruction.variable.addressStringValue;
		}
		else if ([tableColumn.identifier isEqualToString:@"instruction"])
		{
			result = instruction.text;
		}
		else if ([tableColumn.identifier isEqualToString:@"symbols"])
		{
			result = instruction.symbols;
		}
		else if ([tableColumn.identifier isEqualToString:@"bytes"])
		{
			result = instruction.variable.stringValue;
		}
		else if ([tableColumn.identifier isEqualToString:@"breakpoint"])
		{
			result = @([self isBreakPointAtInstruction:instruction]);
		}
	}
	
	return result;
}

- (void)tableView:(NSTableView *)tableView setObjectValue:(id)object forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	if (rowIndex >= 0 && (NSUInteger)rowIndex < self.instructions.count)
	{
		if ([tableColumn.identifier isEqualToString:@"bytes"])
		{
			[self writeStringValue:object atInstructionFromIndex:(NSUInteger)rowIndex];
		}
		else if ([tableColumn.identifier isEqualToString:@"instruction"])
		{
			[self writeInstructionText:object atInstructionFromIndex:(NSUInteger)rowIndex];
		}
		else if ([tableColumn.identifier isEqualToString:@"breakpoint"])
		{
			if (self.selectedInstructions.count > 1)
			{
				self.shouldIgnoreTableViewSelectionChange = YES;
			}
			
			if ([object boolValue])
			{
				[self addBreakPointsToInstructions:self.selectedInstructions];
			}
			else
			{
				[self removeBreakPointsToInstructions:self.selectedInstructions];
			}
		}
	}
}

- (void)tableView:(NSTableView *)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	if ([tableColumn.identifier isEqualToString:@"address"] && rowIndex >= 0 && (NSUInteger)rowIndex < self.instructions.count)
	{
		ZGInstruction *instruction = [self.instructions objectAtIndex:rowIndex];
		BOOL isInstructionBreakPoint = (self.currentBreakPoint && self.registersController.programCounter == instruction.variable.address);
		
		[cell setTextColor:isInstructionBreakPoint ? NSColor.redColor : NSColor.textColor];
	}
}

#pragma mark Modifying instructions

#define ASSEMBLER_ERROR_DOMAIN @"Assembling Failed"
- (NSData *)assembleInstructionText:(NSString *)instructionText atInstructionPointer:(ZGMemoryAddress)instructionPointer usingArchitectureBits:(ZGMemorySize)numberOfBits error:(NSError **)error
{
	NSData *data = [NSData data];
	NSString *outputFileTemplate = [NSTemporaryDirectory() stringByAppendingPathComponent:@"assembler_output.XXXXXX"];
	const char *tempFileTemplateCString = [outputFileTemplate fileSystemRepresentation];
	char *tempFileNameCString = malloc(strlen(tempFileTemplateCString) + 1);
	strcpy(tempFileNameCString, tempFileTemplateCString);
	int fileDescriptor = mkstemp(tempFileNameCString);
	
	if (fileDescriptor != -1)
	{
		close(fileDescriptor);
		
		NSString *outputFilePath = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:tempFileNameCString length:strlen(tempFileNameCString)];
		
		NSTask *task = [[NSTask alloc] init];
		[task setLaunchPath:[[NSBundle mainBundle] pathForResource:@"yasm" ofType:nil]];
		[task setArguments:@[@"--arch=x86", @"-", @"-o", outputFilePath]];
		
		NSPipe *inputPipe = [NSPipe pipe];
		[task setStandardInput:inputPipe];
		
		NSPipe *errorPipe = [NSPipe pipe];
		[task setStandardError:errorPipe];
		
		BOOL failedToLaunchTask = NO;
		
		@try
		{
			[task launch];
		}
		@catch (NSException *exception)
		{
			failedToLaunchTask = YES;
			if (error != nil)
			{
				*error = [NSError errorWithDomain:ASSEMBLER_ERROR_DOMAIN code:kCFStreamErrorDomainCustom userInfo:@{@"description" : [NSString stringWithFormat:@"yasm task failed to launch: Name: %@, Reason: %@", exception.name, exception.reason], @"reason" : exception.reason}];
			}
		}
		
		if (!failedToLaunchTask)
		{
			// yasm likes to be fed in an aligned instruction pointer for its org specifier, so we'll comply with that
			ZGMemoryAddress alignedInstructionPointer = instructionPointer - (instructionPointer % 4);
			NSUInteger numberOfNoppedInstructions = instructionPointer - alignedInstructionPointer;
			
			// clever way of @"nop" * numberOfNoppedInstructions, if it existed
			NSString *nopLine = @"nop\n";
			NSString *nopsString = [@"" stringByPaddingToLength:numberOfNoppedInstructions * nopLine.length withString:nopLine startingAtIndex:0];
			
			NSData *inputData = [[NSString stringWithFormat:@"BITS %lld\norg %lld\n%@%@\n", numberOfBits, alignedInstructionPointer, nopsString, instructionText] dataUsingEncoding:NSUTF8StringEncoding];
			
			[[inputPipe fileHandleForWriting] writeData:inputData];
			[[inputPipe fileHandleForWriting] closeFile];
			
			[task waitUntilExit];
			
			if ([task terminationStatus] == EXIT_SUCCESS)
			{
				NSData *tempData = [NSData dataWithContentsOfFile:outputFilePath];
				
				if (tempData.length <= numberOfNoppedInstructions)
				{
					if (error != nil)
					{
						*error = [NSError errorWithDomain:ASSEMBLER_ERROR_DOMAIN code:kCFStreamErrorDomainCustom userInfo:@{@"reason" : @"nothing was assembled (0 bytes)."}];
					}
				}
				else
				{
					data = [NSData dataWithBytes:tempData.bytes + numberOfNoppedInstructions length:tempData.length - numberOfNoppedInstructions];
				}
			}
			else
			{
				NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
				if (errorData != nil && error != nil)
				{
					NSString *errorString = [[[[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding] componentsSeparatedByString:@"\n"] objectAtIndex:0];
					*error = [NSError errorWithDomain:ASSEMBLER_ERROR_DOMAIN code:kCFStreamErrorDomainCustom userInfo:@{@"reason" : errorString}];
				}
			}
			
			if ([[NSFileManager defaultManager] fileExistsAtPath:outputFilePath])
			{
				[[NSFileManager defaultManager] removeItemAtPath:outputFilePath error:NULL];
			}
		}
	}
	else if (error != nil)
	{
		*error = [NSError errorWithDomain:ASSEMBLER_ERROR_DOMAIN code:kCFStreamErrorDomainCustom userInfo:@{@"reason" : [NSString stringWithFormat:@"failed to open file descriptor on %s.", tempFileNameCString]}];
	}
	
	free(tempFileNameCString);
	
	return data;
}

- (void)writeInstructionText:(NSString *)instructionText atInstructionFromIndex:(NSUInteger)instructionIndex
{
	NSError *error = nil;
	ZGInstruction *firstInstruction = [self.instructions objectAtIndex:instructionIndex];
	NSData *data = [self assembleInstructionText:instructionText atInstructionPointer:firstInstruction.variable.address usingArchitectureBits:self.currentProcess.pointerSize * 8 error:&error];
	if (data.length == 0)
	{
		if (error != nil)
		{
			NSLog(@"%@", error);
			NSRunAlertPanel(@"Failed to Modify Instruction", @"An error occured trying to assemble \"%@\": %@", @"OK", nil, nil, instructionText, [error.userInfo objectForKey:@"reason"]);
		}
	}
	else
	{
		NSMutableData *outputData = [NSMutableData dataWithData:data];
		
		// Fill leftover bytes with NOP's so that the instructions won't 'slide'
		NSUInteger originalOutputLength = outputData.length;
		NSUInteger bytesRead = 0;
		NSUInteger numberOfInstructionsOverwritten = 0;
		
		for (ZGMemorySize currentInstructionIndex = instructionIndex; (bytesRead < originalOutputLength) && (currentInstructionIndex < self.instructions.count); currentInstructionIndex++)
		{
			ZGInstruction *currentInstruction = [self.instructions objectAtIndex:currentInstructionIndex];
			bytesRead += currentInstruction.variable.size;
			numberOfInstructionsOverwritten++;
			
			if (bytesRead > originalOutputLength)
			{
				const int8_t nopValue = NOP_VALUE;
				for (ZGMemorySize byteIndex = currentInstruction.variable.address + currentInstruction.variable.size - (bytesRead - originalOutputLength); byteIndex < currentInstruction.variable.address + currentInstruction.variable.size; byteIndex++)
				{
					[outputData appendBytes:&nopValue length:sizeof(int8_t)];
				}
			}
		}
		
		if (bytesRead < originalOutputLength)
		{
			NSRunAlertPanel(@"Failed to Overwrite Instructions", @"This modification exceeds the boundary of instructions displayed.", @"OK", nil, nil);
		}
		else
		{
			BOOL shouldOverwriteInstructions = YES;
			if (numberOfInstructionsOverwritten > 1 && NSRunAlertPanel(@"Overwrite Instructions", @"This modification will overwrite %ld instructions. Are you sure you want to overwrite them?", @"Cancel", @"Overwrite", nil, numberOfInstructionsOverwritten) != NSAlertAlternateReturn)
			{
				shouldOverwriteInstructions = NO;
			}
			
			if (shouldOverwriteInstructions)
			{
				ZGVariable *newVariable = [[ZGVariable alloc] initWithValue:(void *)outputData.bytes size:outputData.length address:0 type:ZGByteArray qualifier:ZGSigned pointerSize:self.currentProcess.pointerSize];
				
				[self writeStringValue:newVariable.stringValue atInstructionFromIndex:instructionIndex];
			}
		}
	}
}

- (void)writeStringValue:(NSString *)stringValue atInstructionFromIndex:(NSUInteger)initialInstructionIndex
{
	ZGInstruction *instruction = [self.instructions objectAtIndex:initialInstructionIndex];
	
	// Make sure the old and new value that we are writing have the same size in bytes, so that undo/redo will work correctly for different sizes
	
	ZGMemorySize newWriteSize = 0;
	void *newWriteValue = valueFromString(self.currentProcess.is64Bit, stringValue, ZGByteArray, &newWriteSize);
	if (newWriteValue)
	{
		if (newWriteSize > 0)
		{
			void *oldValue = calloc(1, newWriteSize);
			if (oldValue)
			{
				NSUInteger instructionIndex = initialInstructionIndex;
				ZGMemorySize writeIndex = 0;
				while (writeIndex < newWriteSize && instructionIndex < self.instructions.count)
				{
					ZGInstruction *currentInstruction = [self.instructions objectAtIndex:instructionIndex];
					for (ZGMemorySize valueIndex = 0; (writeIndex < newWriteSize) && (valueIndex < currentInstruction.variable.size); valueIndex++, writeIndex++)
					{
						*(char *)(oldValue + writeIndex) = *(char *)(currentInstruction.variable.value + valueIndex);
					}
					
					instructionIndex++;
				}
				
				if (writeIndex >= newWriteSize)
				{
					ZGVariable *newVariable = [[ZGVariable alloc] initWithValue:newWriteValue size:newWriteSize address:instruction.variable.address type:ZGByteArray qualifier:ZGSigned pointerSize:self.currentProcess.pointerSize];
					
					ZGVariable *oldVariable = [[ZGVariable alloc] initWithValue:oldValue size:newWriteSize address:instruction.variable.address type:ZGByteArray qualifier:ZGSigned pointerSize:self.currentProcess.pointerSize];
					
					[self replaceInstructions:@[instruction] fromOldStringValues:@[oldVariable.stringValue] toNewStringValues:@[newVariable.stringValue] inProcess:self.currentProcess recordUndo:YES actionName:@"Instruction Change"];
				}
				
				free(oldValue);
			}
		}
		
		free(newWriteValue);
	}
}

- (void)
	replaceInstructions:(NSArray *)instructions
	fromOldStringValues:(NSArray *)oldStringValues
	toNewStringValues:(NSArray *)newStringValues
	inProcess:(ZGProcess *)process
	recordUndo:(BOOL)shouldRecordUndo
	actionName:(NSString *)actionName
{
	[self replaceInstructions:instructions fromOldStringValues:oldStringValues toNewStringValues:newStringValues inTaskPort:process.processTask is64Bit:process.is64Bit recordUndo:shouldRecordUndo actionName:actionName];
}

- (void)
	replaceInstructions:(NSArray *)instructions
	fromOldStringValues:(NSArray *)oldStringValues
	toNewStringValues:(NSArray *)newStringValues
	inTaskPort:(ZGMemoryMap)taskPort
	is64Bit:(BOOL)is64Bit
	recordUndo:(BOOL)shouldRecordUndo
	actionName:(NSString *)actionName
{
	for (NSUInteger index = 0; index < instructions.count; index++)
	{
		ZGInstruction *instruction = [instructions objectAtIndex:index];
		[self writeStringValue:[newStringValues objectAtIndex:index] atAddress:instruction.variable.address inTaskPort:taskPort is64Bit:is64Bit];
	}
	
	if (shouldRecordUndo)
	{
		if (actionName != nil)
		{
			[self.undoManager setActionName:[actionName stringByAppendingFormat:@"%@", instructions.count == 1 ? @"" : @"s"]];
		}
		
		[[self.undoManager prepareWithInvocationTarget:self] replaceInstructions:instructions fromOldStringValues:newStringValues toNewStringValues:oldStringValues inTaskPort:taskPort is64Bit:is64Bit recordUndo:shouldRecordUndo actionName:actionName];
	}
}

- (void)writeStringValue:(NSString *)stringValue atAddress:(ZGMemoryAddress)address inProcess:(ZGProcess *)process
{
	[self writeStringValue:stringValue atAddress:address inTaskPort:process.processTask is64Bit:process.is64Bit];
}

- (void)writeStringValue:(NSString *)stringValue atAddress:(ZGMemoryAddress)address inTaskPort:(ZGMemoryMap)taskPort is64Bit:(BOOL)is64Bit
{
	ZGMemorySize newSize = 0;
	void *newValue = valueFromString(is64Bit, stringValue, ZGByteArray, &newSize);
	
	[self writeData:[NSData dataWithBytesNoCopy:newValue length:newSize] atAddress:address inTaskPort:taskPort is64Bit:is64Bit];
}

- (BOOL)writeData:(NSData *)data atAddress:(ZGMemoryAddress)address inTaskPort:(ZGMemoryMap)taskPort is64Bit:(BOOL)is64Bit
{
	BOOL success = YES;
	pid_t processID = 0;
	if (!ZGPIDForTaskPort(taskPort, &processID))
	{
		NSLog(@"Error in writeStringValue: method for retrieving process ID");
		success = NO;
	}
	else
	{
		ZGBreakPoint *targetBreakPoint = nil;
		for (ZGBreakPoint *breakPoint in [[[ZGAppController sharedController] breakPointController] breakPoints])
		{
			if (breakPoint.process.processID == processID && breakPoint.variable.address >= address && breakPoint.variable.address < address + data.length)
			{
				targetBreakPoint = breakPoint;
				break;
			}
		}
		
		if (targetBreakPoint == nil)
		{
			if (!ZGWriteBytesIgnoringProtection(taskPort, address, data.bytes, data.length))
			{
				success = NO;
			}
		}
		else
		{
			if (targetBreakPoint.variable.address - address > 0)
			{
				if (!ZGWriteBytesIgnoringProtection(taskPort, address, data.bytes, targetBreakPoint.variable.address - address))
				{
					success = NO;
				}
			}
			
			if (address + data.length - targetBreakPoint.variable.address - 1 > 0)
			{
				if (!ZGWriteBytesIgnoringProtection(taskPort, targetBreakPoint.variable.address + 1, data.bytes + (targetBreakPoint.variable.address + 1 - address), address + data.length - targetBreakPoint.variable.address - 1))
				{
					success = NO;
				}
			}
			
			*(uint8_t *)targetBreakPoint.variable.value = *(uint8_t *)(data.bytes + targetBreakPoint.variable.address - address);
		}
	}
	
	return success;
}

- (void)nopInstructions:(NSArray *)instructions inProcess:(ZGProcess *)process recordUndo:(BOOL)shouldRecordUndo actionName:(NSString *)actionName
{
	[self nopInstructions:instructions inTaskPort:process.processTask is64Bit:process.is64Bit recordUndo:shouldRecordUndo actionName:actionName];
}

- (void)nopInstructions:(NSArray *)instructions inTaskPort:(ZGMemoryMap)taskPort is64Bit:(BOOL)is64Bit recordUndo:(BOOL)shouldRecordUndo actionName:(NSString *)actionName
{
	NSMutableArray *newStringValues = [[NSMutableArray alloc] init];
	NSMutableArray *oldStringValues = [[NSMutableArray alloc] init];
	
	for (NSUInteger instructionIndex = 0; instructionIndex < instructions.count; instructionIndex++)
	{
		ZGInstruction *instruction = [instructions objectAtIndex:instructionIndex];
		[oldStringValues addObject:instruction.variable.stringValue];
		
		NSMutableArray *nopComponents = [[NSMutableArray alloc] init];
		for (NSUInteger nopIndex = 0; nopIndex < instruction.variable.size; nopIndex++)
		{
			[nopComponents addObject:@"90"];
		}
		
		[newStringValues addObject:[nopComponents componentsJoinedByString:@" "]];
	}
	
	[self replaceInstructions:instructions fromOldStringValues:oldStringValues toNewStringValues:newStringValues inTaskPort:taskPort is64Bit:is64Bit recordUndo:shouldRecordUndo actionName:actionName];
}

- (IBAction)nopVariables:(id)sender
{
	[self nopInstructions:[self selectedInstructions] inProcess:self.currentProcess recordUndo:YES actionName:@"NOP Change"];
}

#define INJECT_ERROR_DOMAIN @"INJECT_CODE_FAILED"
- (BOOL)
	injectCode:(NSData *)codeData
	intoAddress:(ZGMemoryAddress)allocatedAddress
	hookingIntoOriginalInstructions:(NSArray *)hookedInstructions
	inTaskPort:(ZGMemoryMap)taskPort
	pointerSize:(ZGMemorySize)pointerSize
	recordUndo:(BOOL)shouldRecordUndo
	error:(NSError **)error
{
	NSMutableData *newInstructionsData = [NSMutableData dataWithData:codeData];
	BOOL success = NO;
	
	ZGSuspendTask(taskPort);
	
	void *nopBuffer = malloc(codeData.length);
	memset(nopBuffer, NOP_VALUE, codeData.length);
	
	if (!ZGWriteBytesIgnoringProtection(taskPort, allocatedAddress, nopBuffer, codeData.length))
	{
		NSLog(@"Error: Failed to write nop buffer..");
		if (error != nil)
		{
			*error = [NSError errorWithDomain:INJECT_ERROR_DOMAIN code:kCFStreamErrorDomainCustom userInfo:@{@"reason" : @"failed to NOP current instructions"}];
		}
	}
	else
	{
		if (!ZGProtect(taskPort, allocatedAddress, codeData.length, VM_PROT_READ | VM_PROT_EXECUTE))
		{
			NSLog(@"Error: Failed to protect memory..");
			if (error != nil)
			{
				*error = [NSError errorWithDomain:INJECT_ERROR_DOMAIN code:kCFStreamErrorDomainCustom userInfo:@{@"reason" : @"failed to change memory protection on new instructions"}];
			}
		}
		else
		{
			[self.undoManager setActionName:@"Inject code"];
			
			[self nopInstructions:hookedInstructions inTaskPort:taskPort is64Bit:pointerSize == sizeof(int64_t) recordUndo:shouldRecordUndo actionName:nil];
			
			ZGInstruction *firstInstruction = [hookedInstructions objectAtIndex:0];
			
			NSData *jumpToIslandData = [self assembleInstructionText:[NSString stringWithFormat:@"jmp %lld", allocatedAddress] atInstructionPointer:firstInstruction.variable.address usingArchitectureBits:pointerSize*8 error:error];
			
			if (jumpToIslandData.length > 0)
			{
				ZGVariable *variable = [[ZGVariable alloc] initWithValue:(void *)jumpToIslandData.bytes size:jumpToIslandData.length address:firstInstruction.variable.address type:ZGByteArray qualifier:0 pointerSize:pointerSize];
				
				[self replaceInstructions:@[firstInstruction] fromOldStringValues:@[firstInstruction.variable.stringValue] toNewStringValues:@[variable.stringValue] inTaskPort:taskPort is64Bit:(pointerSize == sizeof(int64_t)) recordUndo:shouldRecordUndo actionName:nil];
				
				NSData *jumpFromIslandData = [self assembleInstructionText:[NSString stringWithFormat:@"jmp %lld", firstInstruction.variable.address + JUMP_REL32_INSTRUCTION_LENGTH] atInstructionPointer:allocatedAddress + newInstructionsData.length usingArchitectureBits:pointerSize*8 error:error];
				if (jumpFromIslandData.length > 0)
				{
					[newInstructionsData appendData:jumpFromIslandData];
					
					ZGWriteBytesIgnoringProtection(taskPort, allocatedAddress, newInstructionsData.bytes, newInstructionsData.length);
					
					success = YES;
				}
			}
		}
	}
	
	free(nopBuffer);
	
	ZGResumeTask(taskPort);
	
	return success;
}

- (NSArray *)instructionsAtMemoryAddress:(ZGMemoryAddress)address consumingLength:(NSInteger)consumedLength inTaskPort:(ZGMemoryMap)taskPort pointerSize:(ZGMemorySize)pointerSize
{
	NSMutableArray *instructions = [[NSMutableArray alloc] init];
	
	while (consumedLength > 0)
	{
		ZGInstruction *newInstruction = [self findInstructionBeforeAddress:address+1 inTaskPort:taskPort pointerSize:pointerSize];
		if (newInstruction == nil)
		{
			instructions = nil;
			break;
		}
		[instructions addObject:newInstruction];
		consumedLength -= newInstruction.variable.size;
		address += newInstruction.variable.size;
	}
	
	return [instructions copy];
}

- (IBAction)requestCodeInjection:(id)sender
{
	ZGInstruction *firstInstruction = [[self selectedInstructions] objectAtIndex:0];
	NSArray *instructions = [self instructionsAtMemoryAddress:firstInstruction.variable.address consumingLength:JUMP_REL32_INSTRUCTION_LENGTH inTaskPort:self.currentProcess.processTask pointerSize:self.currentProcess.pointerSize];
	if (instructions != nil)
	{
		ZGMemoryAddress allocatedAddress = 0;
		ZGMemorySize numberOfAllocatedBytes = NSPageSize(); // sane default
		ZGPageSize(self.currentProcess.processTask, &numberOfAllocatedBytes);
		
		if (ZGAllocateMemory(self.currentProcess.processTask, &allocatedAddress, numberOfAllocatedBytes))
		{
			void *nopBuffer = malloc(numberOfAllocatedBytes);
			memset(nopBuffer, NOP_VALUE, numberOfAllocatedBytes);
			if (!ZGWriteBytesIgnoringProtection(self.currentProcess.processTask, allocatedAddress, nopBuffer, numberOfAllocatedBytes))
			{
				NSLog(@"Failed to nop allocated memory for code injection");
			}
			free(nopBuffer);
			
			NSString *suggestedCode = [[[instructions valueForKey:@"text"] componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
			
			if (self.codeInjectionController == nil)
			{
				self.codeInjectionController = [[ZGCodeInjectionWindowController alloc] init];
			}
			
			[self.codeInjectionController setSuggestedCode:suggestedCode];
			[self.codeInjectionController attachToWindow:self.window completionHandler:^(NSString *injectedCodeString, BOOL canceled, BOOL *succeeded) {
				if (!canceled)
				{
					NSError *error = nil;
					NSData *injectedCode = [self assembleInstructionText:injectedCodeString atInstructionPointer:allocatedAddress usingArchitectureBits:self.currentProcess.pointerSize*8 error:&error];
					
					if (injectedCode.length == 0 || error != nil || ![self injectCode:injectedCode intoAddress:allocatedAddress hookingIntoOriginalInstructions:instructions inTaskPort:self.currentProcess.processTask pointerSize:self.currentProcess.pointerSize recordUndo:YES error:&error])
					{
						NSLog(@"Error while injecting code");
						NSLog(@"%@", error);
						
						if (!ZGDeallocateMemory(self.currentProcess.processTask, &allocatedAddress, numberOfAllocatedBytes))
						{
							NSLog(@"Error: Failed to deallocate VM memory after failing to inject code..");
						}
						
						*succeeded = NO;
						NSRunAlertPanel(@"Failed to Inject Code", @"An error occured assembling the new code: %@", @"OK", nil, nil, [error.userInfo objectForKey:@"reason"]);
					}
				}
				else
				{
					if (!ZGDeallocateMemory(self.currentProcess.processTask, &allocatedAddress, numberOfAllocatedBytes))
					{
						NSLog(@"Error: Failed to deallocate VM memory after canceling from injecting code..");
					}
				}
			}];
		}
		else
		{
			NSLog(@"Failed to allocate code for code injection");
			NSRunAlertPanel(@"Failed to Allocate Memory", @"An error occured trying to allocate new memory into the process", @"OK", nil, nil);
		}
	}
	else
	{
		NSLog(@"Error: not enough instructions to override!");
		NSRunAlertPanel(@"Failed to Inject Code", @"There was not enough space to override this instruction.", @"OK", nil, nil);
	}
}

#pragma mark Break Points

- (void)removeBreakPointsToInstructions:(NSArray *)instructions
{
	NSMutableArray *changedInstructions = [[NSMutableArray alloc] init];
	
	for (ZGInstruction *instruction in instructions)
	{
		if ([self isBreakPointAtInstruction:instruction])
		{
			[changedInstructions addObject:instruction];
			[[[ZGAppController sharedController] breakPointController] removeBreakPointOnInstruction:instruction inProcess:self.currentProcess];
		}
	}
	
	[self.undoManager setActionName:[NSString stringWithFormat:@"Add Breakpoint%@", changedInstructions.count != 1 ? @"s" : @""]];
	[[self.undoManager prepareWithInvocationTarget:self] addBreakPointsToInstructions:changedInstructions];
	
	[self.instructionsTableView reloadData];
}

- (void)addBreakPointsToInstructions:(NSArray *)instructions
{
	NSMutableArray *changedInstructions = [[NSMutableArray alloc] init];
	
	BOOL addedAtLeastOneBreakPoint = NO;
	
	for (ZGInstruction *instruction in instructions)
	{
		if (![self isBreakPointAtInstruction:instruction])
		{
			[changedInstructions addObject:instruction];
			addedAtLeastOneBreakPoint = [[[ZGAppController sharedController] breakPointController] addBreakPointOnInstruction:instruction inProcess:self.currentProcess delegate:self] || addedAtLeastOneBreakPoint;
		}
	}
	
	if (addedAtLeastOneBreakPoint)
	{
		[self.undoManager setActionName:[NSString stringWithFormat:@"Remove Breakpoint%@", changedInstructions.count != 1 ? @"s" : @""]];
		[[self.undoManager prepareWithInvocationTarget:self] removeBreakPointsToInstructions:changedInstructions];
		[self.instructionsTableView reloadData];
	}
	else
	{
		NSRunAlertPanel(@"Failed to Add Breakpoint", @"A breakpoint could not be added most likely because the instruction's memory protection is not executable.", @"OK", nil, nil);
	}
}

- (IBAction)toggleBreakPoints:(id)sender
{
	if ([self isBreakPointAtInstruction:[self.selectedInstructions objectAtIndex:0]])
	{
		[self removeBreakPointsToInstructions:self.selectedInstructions];
	}
	else
	{
		[self addBreakPointsToInstructions:self.selectedInstructions];
	}
}

- (IBAction)removeAllBreakPoints:(id)sender
{
	[[[ZGAppController sharedController] breakPointController] removeObserver:self];
	[self.undoManager removeAllActions];
	[self.instructionsTableView reloadData];
}

- (void)addHaltedBreakPoint:(ZGBreakPoint *)breakPoint
{
	NSMutableArray *newBreakPoints = [[NSMutableArray alloc] initWithArray:self.haltedBreakPoints];
	[newBreakPoints addObject:breakPoint];
	self.haltedBreakPoints = [NSArray arrayWithArray:newBreakPoints];
	
	if (breakPoint.process.processID == self.currentProcess.processID)
	{
		[self.instructionsTableView reloadData];
	}
}

- (void)removeHaltedBreakPoint:(ZGBreakPoint *)breakPoint
{
	NSMutableArray *newBreakPoints = [[NSMutableArray alloc] initWithArray:self.haltedBreakPoints];
	[newBreakPoints removeObject:breakPoint];
	self.haltedBreakPoints = [NSArray arrayWithArray:newBreakPoints];
	
	if (breakPoint.process.processID == self.currentProcess.processID)
	{
		[self.instructionsTableView reloadData];
	}
}

- (ZGBreakPoint *)currentBreakPoint
{
	ZGBreakPoint *currentBreakPoint = nil;
	
	for (ZGBreakPoint *breakPoint in self.haltedBreakPoints)
	{
		if (breakPoint.process.processID == self.currentProcess.processID)
		{
			currentBreakPoint = breakPoint;
			break;
		}
	}
	
	return currentBreakPoint;
}

- (ZGInstruction *)findInstructionInTableAtAddress:(ZGMemoryAddress)targetAddress
{
	ZGInstruction *foundInstruction = [self.instructions zgBinarySearchUsingBlock:^NSComparisonResult(__unsafe_unretained ZGInstruction *instruction) {
		if (instruction.variable.address < targetAddress)
		{
			return NSOrderedAscending;
		}
		else if (instruction.variable.address > targetAddress)
		{
			return NSOrderedDescending;
		}
		else
		{
			return NSOrderedSame;
		}
	}];
	
	return foundInstruction;
}

- (void)jumpProgramCounterToAddress:(ZGMemoryAddress)newAddress
{
	if (self.currentBreakPoint && !self.disassembling)
	{
		ZGMemoryAddress currentAddress = [self.registersController programCounter];
		[self.registersController changeProgramCounter:newAddress];
		[[self.undoManager prepareWithInvocationTarget:self] jumpProgramCounterToAddress:currentAddress];
		[self.undoManager setActionName:@"Jump"];
	}
}

- (IBAction)jump:(id)sender
{
	ZGInstruction *instruction = [self.selectedInstructions objectAtIndex:0];
	[self jumpProgramCounterToAddress:instruction.variable.address];
}

- (void)updateRegisters
{
	[self.registersController updateRegistersFromBreakPoint:self.currentBreakPoint programCounterChange:^{
		if (self.currentBreakPoint)
		{
			[self.instructionsTableView reloadData];
		}
	}];
}

- (void)breakPointDidHit:(ZGBreakPoint *)breakPoint
{	
	[self removeHaltedBreakPoint:self.currentBreakPoint];
	[self addHaltedBreakPoint:breakPoint];
	
	if (self.currentBreakPoint)
	{
		if (!self.window.isVisible)
		{
			[self showWindow:nil];
		}
		
		[self updateRegisters];
		
		[self toggleBacktraceView:NSOnState];
		
		[self jumpToMemoryAddress:self.registersController.programCounter];
		
		[self.backtraceController	updateBacktraceWithBasePointer:self.registersController.basePointer instructionPointer:self.registersController.programCounter inProcess:self.currentProcess];
		
		BOOL shouldShowNotification = YES;
		
		if (self.currentBreakPoint.hidden)
		{
			if (breakPoint.basePointer == self.registersController.basePointer)
			{
				[[[ZGAppController sharedController] breakPointController] removeInstructionBreakPoint:breakPoint];
			}
			else
			{
				[self continueFromBreakPoint:self.currentBreakPoint];
				shouldShowNotification = NO;
			}
		}
		
		if (shouldShowNotification && NSClassFromString(@"NSUserNotification"))
		{
			NSUserNotification *userNotification = [[NSUserNotification alloc] init];
			userNotification.title = @"Hit Breakpoint";
			userNotification.subtitle = self.currentProcess.name;
			userNotification.informativeText = [NSString stringWithFormat:@"Stopped at breakpoint %@", self.currentBreakPoint.variable.addressStringValue];
			[[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:userNotification];
		}
	}
}

- (void)resumeBreakPoint:(ZGBreakPoint *)breakPoint
{
	[[[ZGAppController sharedController] breakPointController] resumeFromBreakPoint:breakPoint];
	[self removeHaltedBreakPoint:breakPoint];
}

- (void)continueFromBreakPoint:(ZGBreakPoint *)breakPoint
{
	[[[ZGAppController sharedController] breakPointController] removeSingleStepBreakPointsFromBreakPoint:breakPoint];
	[self resumeBreakPoint:breakPoint];
	[self toggleBacktraceView:NSOffState];
}

- (IBAction)continueExecution:(id)sender
{
	[self continueFromBreakPoint:self.currentBreakPoint];
}

- (IBAction)stepInto:(id)sender
{
	[[[ZGAppController sharedController] breakPointController] addSingleStepBreakPointFromBreakPoint:self.currentBreakPoint];
	[self resumeBreakPoint:self.currentBreakPoint];
}

- (IBAction)stepOver:(id)sender
{
	ZGInstruction *currentInstruction = [self findInstructionBeforeAddress:self.registersController.programCounter + 1 inProcess:self.currentProcess];
	if ([currentInstruction isCallMnemonic])
	{
		ZGInstruction *nextInstruction = [self findInstructionBeforeAddress:currentInstruction.variable.address + currentInstruction.variable.size + 1 inProcess:self.currentProcess];
		
		[[[ZGAppController sharedController] breakPointController] addBreakPointOnInstruction:nextInstruction inProcess:self.currentProcess thread:self.currentBreakPoint.thread basePointer:self.registersController.basePointer delegate:self];
		[self continueExecution:nil];
	}
	else
	{
		[self stepInto:nil];
	}
}

- (IBAction)stepOut:(id)sender
{
	ZGInstruction *outterInstruction = [self.backtraceController.instructions objectAtIndex:1];
	ZGInstruction *returnInstruction = [self findInstructionBeforeAddress:outterInstruction.variable.address + outterInstruction.variable.size + 1 inProcess:self.currentProcess];
	
	[[[ZGAppController sharedController] breakPointController] addBreakPointOnInstruction:returnInstruction inProcess:self.currentProcess thread:self.currentBreakPoint.thread basePointer:[[self.backtraceController.basePointers objectAtIndex:1] unsignedLongLongValue] delegate:self];
	
	[self continueExecution:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
	[[[ZGAppController sharedController] breakPointController] removeObserver:self];
	
	for (ZGBreakPoint *breakPoint in self.haltedBreakPoints)
	{
		[self continueFromBreakPoint:breakPoint];
	}
}

- (BOOL)isProcessIdentifierHalted:(pid_t)processIdentifier
{
	BOOL foundProcess = NO;
	for (ZGBreakPoint *breakPoint in self.haltedBreakPoints)
	{
		if (breakPoint.process.processID == processIdentifier)
		{
			foundProcess = YES;
			break;
		}
	}
	return foundProcess;
}

#pragma mark Memory Viewer

- (IBAction)showMemoryViewer:(id)sender
{
	ZGInstruction *selectedInstruction = [[self selectedInstructions] objectAtIndex:0];
	[[[ZGAppController sharedController] memoryViewer] jumpToMemoryAddress:selectedInstruction.variable.address withSelectionLength:selectedInstruction.variable.size inProcess:self.currentProcess];
}

@end