// Copyright 2017-2020 Firefly Studio. All Rights Reserved.


#include "EFDCore.h"

bool EFDCore::OpenFileDialogCore(const FString& DialogTitle, const FString& DefaultPath, const FString& DefaultFile, const FString& FileTypes, uint32 Flags, TArray< FString >& OutFilenames)
{
	// Calling the FileDialogShared function using save parameter with false.
	int32 OutFilterIndex = 0;
	return FileDialogShared(false, nullptr, DialogTitle, DefaultPath, DefaultFile, FileTypes, Flags, OutFilenames, OutFilterIndex);
}

bool EFDCore::SaveFileDialogCore(const FString& DialogTitle, const FString& DefaultPath, const FString& DefaultFile, const FString& FileTypes, uint32 Flags, TArray< FString >& OutFilenames)
{
	// Calling the FileDialogShared function using save parameter.
	int32 OutFilterIndex = 0;
	return FileDialogShared(true, nullptr, DialogTitle, DefaultPath, DefaultFile, FileTypes, Flags, OutFilenames, OutFilterIndex);
}

bool EFDCore::OpenFolderDialogCore(const FString& DialogTitle, const FString& DefaultPath, FString& OutFoldername)
{
	// Calling the main open folder dialog function.
	return OpenFolderDialogInner(nullptr, DialogTitle, DefaultPath, OutFoldername);
}

#if !PLATFORM_WINDOWS && !PLATFORM_MAC && !PLATFORM_LINUX
// Platform-specific implementations live in the Windows/, Mac/ and Linux/ subfolders, which Unreal
// Build Tool automatically restricts to their matching platform. This fallback covers everything else.
bool EFDCore::FileDialogShared(bool bSave, const void* ParentWindowHandle, const FString& DialogTitle, const FString& DefaultPath, const FString& DefaultFile, const FString& FileTypes, uint32 Flags, TArray<FString>& OutFilenames, int32& OutFilterIndex)
{
	return false;
}

bool EFDCore::OpenFolderDialogInner(const void* ParentWindowHandle, const FString& DialogTitle, const FString& DefaultPath, FString& OutFolderName)
{
	return false;
}
#endif
