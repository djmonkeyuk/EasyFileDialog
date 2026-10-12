// Copyright 2017-2020 Firefly Studio. All Rights Reserved.


#include "EFDCore.h"

#include "HAL/FileManager.h"
#include "Mac/CocoaThread.h"
#include "Misc/Paths.h"

#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// AppKit panels must be driven from the main thread. On Mac the game thread is a separate native
// thread from the OS main thread, and the main thread's run loop is only pumped through Unreal's
// own FCocoaRunLoopSource mechanism (see Mac/CocoaThread.h) rather than the standard GCD main
// queue, so a plain dispatch_sync(dispatch_get_main_queue(), ...) never gets serviced and
// deadlocks the game thread. MainThreadReturn (declared there) routes through that mechanism instead.

// Lets the user pick which of the supplied file type pairs to filter the panel by.
// FileTypes pairs match the Windows implementation: "Description|*.ext|Description2|*.ext2".
@interface FEFDFileDialogAccessoryView : NSView
{
@private
	NSPopUpButton* PopUpButton;
	NSSavePanel* DialogPanel;
	NSArray<NSString*>* FileTypePairs;
	int32 SelectedExtensionIndex;
}
- (id)initWithDialogPanel:(NSSavePanel*)Panel fileTypePairs:(NSArray<NSString*>*)Pairs;
- (int32)selectedExtensionIndex;
@end

@implementation FEFDFileDialogAccessoryView

- (id)initWithDialogPanel:(NSSavePanel*)Panel fileTypePairs:(NSArray<NSString*>*)Pairs
{
	self = [super initWithFrame:NSMakeRect(0.0, 0.0, 260.0, 32.0)];
	DialogPanel = Panel;
	FileTypePairs = Pairs;
	SelectedExtensionIndex = 0;

	NSTextField* Label = [[NSTextField alloc] initWithFrame:NSMakeRect(0.0, 6.0, 88.0, 24.0)];
	[Label setStringValue:@"File type:"];
	[Label setEditable:NO];
	[Label setBordered:NO];
	[Label setDrawsBackground:NO];
	[self addSubview:Label];

	PopUpButton = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(88.0, 2.0, 170.0, 24.0)];
	[PopUpButton setTarget:self];
	[PopUpButton setAction:@selector(onSelectionChanged:)];

	const NSUInteger NumPairs = FileTypePairs.count / 2;
	for (NSUInteger Index = 0; Index < NumPairs; ++Index)
	{
		[PopUpButton addItemWithTitle:FileTypePairs[Index * 2]];
	}
	[self addSubview:PopUpButton];

	[self applyExtensionAtIndex:0];

	return self;
}

- (void)onSelectionChanged:(id)Sender
{
	[self applyExtensionAtIndex:[PopUpButton indexOfSelectedItem]];
}

- (void)applyExtensionAtIndex:(NSInteger)Index
{
	if (Index < 0)
	{
		return;
	}

	SelectedExtensionIndex = (int32)Index;

	NSString* ExtensionPattern = FileTypePairs[Index * 2 + 1];
	if ([ExtensionPattern isEqualToString:@"*.*"])
	{
		DialogPanel.allowedContentTypes = @[];
		return;
	}

	NSArray<NSString*>* Wildcards = [ExtensionPattern componentsSeparatedByString:@";"];
	NSMutableArray<UTType*>* Types = [NSMutableArray arrayWithCapacity:Wildcards.count];
	NSCharacterSet* TrimSet = [NSCharacterSet characterSetWithCharactersInString:@"*."];
	for (NSString* Wildcard in Wildcards)
	{
		NSString* CleanExtension = [Wildcard stringByTrimmingCharactersInSet:TrimSet];
		UTType* Type = [UTType typeWithFilenameExtension:CleanExtension];
		if (Type)
		{
			[Types addObject:Type];
		}
	}
	DialogPanel.allowedContentTypes = Types;
}

- (int32)selectedExtensionIndex
{
	return SelectedExtensionIndex;
}

@end

bool EFDCore::FileDialogShared(bool bSave, const void* ParentWindowHandle, const FString& DialogTitle, const FString& DefaultPath, const FString& DefaultFile, const FString& FileTypes, uint32 Flags, TArray<FString>& OutFilenames, int32& OutFilterIndex)
{
	UE_LOG(LogTemp, Warning, TEXT("[EFD] FileDialogShared entered on %s (IsInGameThread=%d, IsInMainThread=%d)"), FPlatformTLS::GetCurrentThreadId() == GGameThreadId ? TEXT("game thread") : TEXT("other thread"), IsInGameThread(), FPlatformTLS::GetCurrentThreadId() == GMacMainThreadId);

	// Nicely formatted file types for lookup later and suitable to append to filenames without extensions.
	// The strings must be in pairs, as with the Windows implementation: Pair1Description|Pair1Extension|Pair2Description|Pair2Extension...
	TArray<FString> UnformattedExtensions;
	FileTypes.ParseIntoArray(UnformattedExtensions, TEXT("|"), true);

	TArray<FString> CleanExtensionList;
	for (int32 ExtensionIndex = 1; ExtensionIndex < UnformattedExtensions.Num(); ExtensionIndex += 2)
	{
		const FString& Extension = UnformattedExtensions[ExtensionIndex];
		if (Extension != TEXT("*.*"))
		{
			int32 WildCardIndex = Extension.Find(TEXT("*"));
			FString CleanExtension = WildCardIndex != INDEX_NONE ? Extension.RightChop(WildCardIndex + 1) : Extension;
			CleanExtension.RemoveFromStart(TEXT("."));
			CleanExtensionList.Add(CleanExtension);
		}
		else
		{
			CleanExtensionList.Add(FString());
		}
	}

	NSMutableArray<NSString*>* FileTypePairs = [NSMutableArray arrayWithCapacity:UnformattedExtensions.Num()];
	for (const FString& Part : UnformattedExtensions)
	{
		[FileTypePairs addObject:Part.GetNSString()];
	}
	if (FileTypePairs.count == 2)
	{
		// Only one pair was supplied. Duplicate it so the popup has something to show.
		[FileTypePairs addObjectsFromArray:[FileTypePairs copy]];
	}

	NSString* Title = DialogTitle.GetNSString();
	NSString* InitialDirectory = FPaths::ConvertRelativePathToFull(DefaultPath).GetNSString();
	NSString* InitialFileName = DefaultFile.GetNSString();
	const bool bAllowMultiple = (Flags & EEasyFileDialogFlags::Multiple) != 0;

	__block TArray<FString> SelectedFiles;
	__block int32 SelectedExtensionIndex = 0;

	UE_LOG(LogTemp, Warning, TEXT("[EFD] About to call MainThreadReturn (MainRunLoopSource should already be registered by now)"));

	bool bSuccess = MainThreadReturn(^{
		UE_LOG(LogTemp, Warning, TEXT("[EFD] Block executing on main thread, creating panel"));
		NSSavePanel* Panel = bSave ? [NSSavePanel savePanel] : [NSOpenPanel openPanel];
		[Panel setTitle:Title];
		[Panel setCanCreateDirectories:bSave];

		if (InitialDirectory.length > 0)
		{
			[Panel setDirectoryURL:[NSURL fileURLWithPath:InitialDirectory isDirectory:YES]];
		}

		if (InitialFileName.length > 0)
		{
			[Panel setNameFieldStringValue:InitialFileName];
		}

		if (!bSave)
		{
			NSOpenPanel* OpenPanel = (NSOpenPanel*)Panel;
			[OpenPanel setCanChooseFiles:YES];
			[OpenPanel setCanChooseDirectories:NO];
			[OpenPanel setAllowsMultipleSelection:bAllowMultiple];
		}

		FEFDFileDialogAccessoryView* AccessoryView = nil;
		if (FileTypePairs.count > 0)
		{
			AccessoryView = [[FEFDFileDialogAccessoryView alloc] initWithDialogPanel:Panel fileTypePairs:FileTypePairs];
			[Panel setAccessoryView:AccessoryView];
		}

		// In exclusive Fullscreen mode Unreal raises the game window to CGShieldingWindowLevel()+1
		// (see MacWindow.cpp) so it covers the menu bar and dock. Panels default to
		// NSModalPanelWindowLevel, which is far below that, so without this the panel would run its
		// modal loop entirely hidden behind the game window.
		NSInteger GameWindowLevel = [[NSApp keyWindow] level];
		if (GameWindowLevel >= [Panel level])
		{
			[Panel setLevel:GameWindowLevel + 1];
		}

		UE_LOG(LogTemp, Warning, TEXT("[EFD] Calling runModal, panel isVisible=%d level=%ld"), (int)[Panel isVisible], (long)[Panel level]);

		bool bOkPressed = false;
		NSModalResponse Response = [Panel runModal];
		UE_LOG(LogTemp, Warning, TEXT("[EFD] runModal returned %ld"), (long)Response);
		if (Response == NSModalResponseOK)
		{
			bOkPressed = true;
			SelectedExtensionIndex = AccessoryView ? [AccessoryView selectedExtensionIndex] : 0;

			if (bSave)
			{
				SelectedFiles.Add(FString([[Panel URL] path]));
			}
			else
			{
				for (NSURL* URL in [(NSOpenPanel*)Panel URLs])
				{
					SelectedFiles.Add(FString([URL path]));
				}
			}
		}

		[AccessoryView release];
		[Panel close];
		return bOkPressed;
	});

	UE_LOG(LogTemp, Warning, TEXT("[EFD] MainThreadReturn came back, bSuccess=%d"), bSuccess);

	if (!bSuccess)
	{
		return false;
	}

	OutFilterIndex = SelectedExtensionIndex;
	FString Extension = CleanExtensionList.IsValidIndex(OutFilterIndex) ? CleanExtensionList[OutFilterIndex] : FString();

	for (FString& SelectedFile : SelectedFiles)
	{
		SelectedFile = IFileManager::Get().ConvertToRelativePath(*SelectedFile);

		if (FPaths::GetExtension(SelectedFile).IsEmpty() && !Extension.IsEmpty())
		{
			SelectedFile += TEXT(".") + Extension;
		}

		FPaths::NormalizeFilename(SelectedFile);
	}

	OutFilenames = MoveTemp(SelectedFiles);
	return true;
}

bool EFDCore::OpenFolderDialogInner(const void* ParentWindowHandle, const FString& DialogTitle, const FString& DefaultPath, FString& OutFolderName)
{
	UE_LOG(LogTemp, Warning, TEXT("[EFD] OpenFolderDialogInner entered, IsInGameThread=%d"), IsInGameThread());

	NSString* Title = DialogTitle.GetNSString();
	NSString* InitialDirectory = FPaths::ConvertRelativePathToFull(DefaultPath).GetNSString();

	__block FString ResultFolder;

	bool bSuccess = MainThreadReturn(^{
		NSOpenPanel* Panel = [NSOpenPanel openPanel];
		[Panel setTitle:Title];
		[Panel setCanChooseFiles:NO];
		[Panel setCanChooseDirectories:YES];
		[Panel setAllowsMultipleSelection:NO];
		[Panel setCanCreateDirectories:YES];

		if (InitialDirectory.length > 0)
		{
			[Panel setDirectoryURL:[NSURL fileURLWithPath:InitialDirectory isDirectory:YES]];
		}

		// See the comment in FileDialogShared: exclusive Fullscreen games raise their window above
		// the panel's default level, hiding it behind the game window otherwise.
		NSInteger GameWindowLevel = [[NSApp keyWindow] level];
		if (GameWindowLevel >= [Panel level])
		{
			[Panel setLevel:GameWindowLevel + 1];
		}

		UE_LOG(LogTemp, Warning, TEXT("[EFD] Calling runModal for folder panel, isVisible=%d level=%ld"), (int)[Panel isVisible], (long)[Panel level]);

		bool bOkPressed = false;
		NSModalResponse Response = [Panel runModal];
		UE_LOG(LogTemp, Warning, TEXT("[EFD] folder runModal returned %ld"), (long)Response);
		if (Response == NSModalResponseOK)
		{
			NSURL* FolderURL = [[Panel URLs] firstObject];
			if (FolderURL)
			{
				ResultFolder = FString([FolderURL path]);
				bOkPressed = true;
			}
		}

		[Panel close];
		return bOkPressed;
	});

	UE_LOG(LogTemp, Warning, TEXT("[EFD] OpenFolderDialogInner MainThreadReturn came back, bSuccess=%d"), bSuccess);

	if (bSuccess)
	{
		FPaths::NormalizeDirectoryName(ResultFolder);
		OutFolderName = ResultFolder;
	}

	return bSuccess;
}
