// Copyright 2017-2020 Firefly Studio. All Rights Reserved.


#include "EFDCore.h"

#include "HAL/FileManager.h"
#include "HAL/PlatformProcess.h"
#include "Misc/Paths.h"

// There's no single native toolkit API that works in-process across every Linux desktop, so this
// shells out to the desktop's own file-picker binary instead: zenity (GTK/GNOME) first, falling
// back to kdialog (KDE) if zenity isn't installed. FileTypes pairs match the Windows/Mac
// implementations: "Description|*.ext;*.ext2|Description2|*.ext3".
//
// Neither utility reports back which filter the user picked (unlike Windows' GetOpenFileName or
// Mac's NSSavePanel accessory view), so OutFilterIndex always resolves to the first filter pair -
// the same fallback the Windows/Mac code uses when a filename already has an extension.

namespace
{
	enum class EDialogUtility : uint8
	{
		None,
		Zenity,
		KDialog
	};

	bool IsUtilityAvailable(const TCHAR* Utility)
	{
		int32 ReturnCode = -1;
		return FPlatformProcess::ExecProcess(Utility, TEXT("--version"), &ReturnCode, nullptr, nullptr) && ReturnCode == 0;
	}

	EDialogUtility FindDialogUtility()
	{
		static const EDialogUtility Cached = []
		{
			if (IsUtilityAvailable(TEXT("zenity")))
			{
				return EDialogUtility::Zenity;
			}
			if (IsUtilityAvailable(TEXT("kdialog")))
			{
				return EDialogUtility::KDialog;
			}
			return EDialogUtility::None;
		}();
		return Cached;
	}

	// Wraps a value as a single command-line argument - double quotes, with any embedded quotes
	// doubled so Unreal's own argument tokenizer (there's no real shell involved) puts it back
	// together as one token. Also how a real newline can be smuggled into a single argument, which
	// the kdialog filter list below relies on.
	FString QuoteArg(const FString& Value)
	{
		return FString::Printf(TEXT("\"%s\""), *Value.Replace(TEXT("\""), TEXT("\"\"")));
	}

	// FileTypes come in as "Description|*.ext1;*.ext2|Description2|*.ext3" pairs (semicolons
	// separate multiple patterns within one pair, same as the Mac implementation). OutPatterns
	// holds each pair's patterns re-joined with spaces (what zenity/kdialog expect); OutExtensions
	// holds the same "clean extension to append if one's missing" guess the Windows/Mac
	// implementations make - just the text after the first "*" of the pair's raw (un-split) pattern.
	void ParseFilterPairs(const FString& FileTypes, TArray<FString>& OutDescriptions, TArray<FString>& OutPatterns, TArray<FString>& OutExtensions)
	{
		TArray<FString> Parts;
		FileTypes.ParseIntoArray(Parts, TEXT("|"), true);

		for (int32 PairIndex = 0; PairIndex + 1 < Parts.Num(); PairIndex += 2)
		{
			const FString& Pattern = Parts[PairIndex + 1];

			OutDescriptions.Add(Parts[PairIndex]);
			OutPatterns.Add(Pattern.Replace(TEXT(";"), TEXT(" ")));

			if (Pattern != TEXT("*.*"))
			{
				const int32 WildCardIndex = Pattern.Find(TEXT("*"));
				FString CleanExtension = WildCardIndex != INDEX_NONE ? Pattern.RightChop(WildCardIndex + 1) : Pattern;
				CleanExtension.RemoveFromStart(TEXT("."));
				OutExtensions.Add(CleanExtension);
			}
			else
			{
				OutExtensions.Add(FString());
			}
		}
	}
}

bool EFDCore::FileDialogShared(bool bSave, const void* ParentWindowHandle, const FString& DialogTitle, const FString& DefaultPath, const FString& DefaultFile, const FString& FileTypes, uint32 Flags, TArray<FString>& OutFilenames, int32& OutFilterIndex)
{
	const EDialogUtility Utility = FindDialogUtility();
	if (Utility == EDialogUtility::None)
	{
		return false;
	}

	const bool bMultiple = (Flags & EEasyFileDialogFlags::Multiple) != 0;

	TArray<FString> FilterDescriptions;
	TArray<FString> FilterPatterns;
	TArray<FString> CleanExtensionList;
	ParseFilterPairs(FileTypes, FilterDescriptions, FilterPatterns, CleanExtensionList);

	const FString InitialDirectory = FPaths::ConvertRelativePathToFull(DefaultPath);
	const FString InitialPath = DefaultFile.IsEmpty() ? (InitialDirectory / TEXT("")) : (InitialDirectory / DefaultFile);

	FString Args;
	FString StdOut;
	int32 ReturnCode = -1;
	bool bInvoked = false;

	if (Utility == EDialogUtility::Zenity)
	{
		Args = TEXT("--file-selection");
		if (bSave)
		{
			Args += TEXT(" --save --confirm-overwrite");
		}
		if (bMultiple)
		{
			// Zenity's default multi-select separator ("|") is kept rather than overridden, since
			// filenames can't contain it on any real Linux filesystem in practice.
			Args += TEXT(" --multiple");
		}
		Args += FString::Printf(TEXT(" --title=%s"), *QuoteArg(DialogTitle));
		Args += FString::Printf(TEXT(" --filename=%s"), *QuoteArg(InitialPath));

		for (int32 FilterIndex = 0; FilterIndex < FilterDescriptions.Num(); ++FilterIndex)
		{
			Args += FString::Printf(TEXT(" --file-filter=%s"), *QuoteArg(FilterDescriptions[FilterIndex] + TEXT(" | ") + FilterPatterns[FilterIndex]));
		}

		bInvoked = FPlatformProcess::ExecProcess(TEXT("zenity"), *Args, &ReturnCode, &StdOut, nullptr);
	}
	else // KDialog
	{
		Args = bSave ? TEXT("--getsavefilename") : TEXT("--getopenfilename");
		if (bMultiple && !bSave)
		{
			Args += TEXT(" --multiple --separate-output");
		}
		Args += FString::Printf(TEXT(" --title %s"), *QuoteArg(DialogTitle));
		Args += FString::Printf(TEXT(" %s"), *QuoteArg(InitialPath));

		if (FilterDescriptions.Num() > 0)
		{
			FString FilterList;
			for (int32 FilterIndex = 0; FilterIndex < FilterDescriptions.Num(); ++FilterIndex)
			{
				if (FilterIndex > 0)
				{
					FilterList += TEXT("\n");
				}
				FilterList += FString::Printf(TEXT("%s (%s)"), *FilterDescriptions[FilterIndex], *FilterPatterns[FilterIndex]);
			}
			Args += FString::Printf(TEXT(" %s"), *QuoteArg(FilterList));
		}

		bInvoked = FPlatformProcess::ExecProcess(TEXT("kdialog"), *Args, &ReturnCode, &StdOut, nullptr);
	}

	if (!bInvoked || ReturnCode != 0)
	{
		// Non-zero/failed exec means the dialog was cancelled (or the utility couldn't run) rather
		// than a real error, matching GetOpenFileName/GetSaveFileName returning false on cancel.
		return false;
	}

	StdOut.TrimEndInline();
	if (StdOut.IsEmpty())
	{
		return false;
	}

	const TCHAR* Separator = (Utility == EDialogUtility::Zenity) ? TEXT("|") : TEXT("\n");

	TArray<FString> SelectedFiles;
	StdOut.ParseIntoArray(SelectedFiles, Separator, true);
	if (SelectedFiles.Num() == 0)
	{
		return false;
	}

	OutFilterIndex = 0;
	const FString Extension = CleanExtensionList.IsValidIndex(OutFilterIndex) ? CleanExtensionList[OutFilterIndex] : FString();

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
	const EDialogUtility Utility = FindDialogUtility();
	if (Utility == EDialogUtility::None)
	{
		return false;
	}

	const FString InitialDirectory = FPaths::ConvertRelativePathToFull(DefaultPath);

	FString Args;
	FString StdOut;
	int32 ReturnCode = -1;
	bool bInvoked = false;

	if (Utility == EDialogUtility::Zenity)
	{
		Args = TEXT("--file-selection --directory");
		Args += FString::Printf(TEXT(" --title=%s"), *QuoteArg(DialogTitle));
		Args += FString::Printf(TEXT(" --filename=%s"), *QuoteArg(InitialDirectory / TEXT("")));

		bInvoked = FPlatformProcess::ExecProcess(TEXT("zenity"), *Args, &ReturnCode, &StdOut, nullptr);
	}
	else // KDialog
	{
		Args = TEXT("--getexistingdirectory");
		Args += FString::Printf(TEXT(" --title %s"), *QuoteArg(DialogTitle));
		Args += FString::Printf(TEXT(" %s"), *QuoteArg(InitialDirectory));

		bInvoked = FPlatformProcess::ExecProcess(TEXT("kdialog"), *Args, &ReturnCode, &StdOut, nullptr);
	}

	if (!bInvoked || ReturnCode != 0)
	{
		return false;
	}

	StdOut.TrimEndInline();
	if (StdOut.IsEmpty())
	{
		return false;
	}

	OutFolderName = StdOut;
	FPaths::NormalizeDirectoryName(OutFolderName);

	return true;
}
