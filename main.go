package main

import (
	"fmt"
	"github.com/taurusxin/ncmdump-go/ncmcrypt"
	"github.com/taurusxin/ncmdump-go/utils"
	"os"
	"path/filepath"

	flag "github.com/spf13/pflag"
)

func processFile(filePath string, outputDir string) error {
	// skip if the extension is not .ncm
	if filePath[len(filePath)-4:] != ".ncm" {
		return nil
	}

	// process the file
	currentFile, err := ncmcrypt.NewNeteaseCloudMusic(filePath)
	if err != nil {
		utils.ErrorPrintfln("Reading '%s' failed: %s", filePath, err.Error())
		return err
	}
	dump, err := currentFile.Dump(outputDir)
	if err != nil {
		utils.ErrorPrintfln("Processing '%s' failed: %s", filePath, err.Error())
		return err
	}
	if dump {
		metadata, err := currentFile.FixMetadata(true)
		if !metadata {
			utils.WarningPrintfln("Fix metadata for '%s' failed: %s", filePath, err.Error())
			return err
		}
		utils.DonePrintfln("'%s' -> '%s'", filePath, currentFile.GetDumpFilePath())
	}
	return nil
}

func main() {
	var sourceDir string
	var outputDir string
	showHelp := flag.BoolP("help", "h", false, "Display help message")
	showVersion := flag.BoolP("version", "v", false, "Display version information")
	processRecursive := flag.BoolP("recursive", "r", false, "Process all files in the directory recursively")
	flag.StringVarP(&outputDir, "output", "o", "", "Output directory for the dump files")
	flag.StringVarP(&sourceDir, "dir", "d", "", "Process all files in the directory")
	flag.Parse()

	if len(os.Args) == 1 {
		flag.Usage()
		os.Exit(0)
	}

	if *showHelp {
		flag.Usage()
		os.Exit(0)
	}

	if *showVersion {
		fmt.Println("ncmdump version 1.7.0")
		os.Exit(0)
	}

	if !flag.Lookup("dir").Changed && sourceDir == "" && len(flag.Args()) == 0 {
		flag.Usage()
		os.Exit(1)
	}

	if flag.Lookup("recursive").Changed && !flag.Lookup("dir").Changed {
		utils.ErrorPrintfln("The -r option can only be used with the -d option")
		os.Exit(1)
	}

	outputDirSpecified := flag.Lookup("output").Changed

	if outputDirSpecified {
		if utils.PathExists(outputDir) {
			if !utils.IsDir(outputDir) {
				utils.ErrorPrintfln("Output directory '%s' is not valid.", outputDir)
				os.Exit(1)
			}
		} else {
			_ = os.MkdirAll(outputDir, os.ModePerm)
		}
	}

	if sourceDir != "" {
		if !utils.IsDir(sourceDir) {
			utils.ErrorPrintfln("The source directory '%s' is not valid.", sourceDir)
			os.Exit(1)
		}

		if *processRecursive {
			_ = filepath.WalkDir(sourceDir, func(p string, d os.DirEntry, err_ error) error {
				if !outputDirSpecified {
					outputDir = sourceDir
				}
				relativePath := utils.GetRelativePath(sourceDir, p)
				destinationPath := filepath.Join(outputDir, relativePath)

				if utils.IsRegularFile(p) {
					parentDir := filepath.Dir(destinationPath)
					_ = os.MkdirAll(parentDir, os.ModePerm)
					_ = processFile(p, parentDir)
				}
				return nil
			})
		} else {
			// dump files in the folder
			files, err := os.ReadDir(sourceDir)
			if err != nil {
				utils.ErrorPrintfln("Unable to read directory: '%s'", sourceDir)
				os.Exit(1)
			}

			for _, file := range files {
				if file.IsDir() {
					continue
				}

				filePath := filepath.Join(sourceDir, file.Name())
				if outputDirSpecified {
					_ = processFile(filePath, outputDir)
				} else {
					_ = processFile(filePath, sourceDir)
				}
			}
		}
	} else {
		// process files from args
		for _, filePath := range flag.Args() {
			// skip if the extension is not .ncm
			if filePath[len(filePath)-4:] != ".ncm" {
				continue
			}
			if outputDirSpecified {
				_ = processFile(filePath, outputDir)
			} else {
				_ = processFile(filePath, sourceDir)
			}
		}
	}

}
