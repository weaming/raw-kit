package main

import (
	"fmt"
	flag "github.com/spf13/pflag"
	"ncmdump/ncmcrypt"
	"os"
	"path/filepath"
)

func processFile(filePath string) error {
	currentFile, err := ncmcrypt.NewNeteaseCloudMusic(filePath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[Error] Reading '%s' failed: '%s'\n", filePath, err.Error())
		return err
	}
	dump, err := currentFile.Dump()
	if err != nil {
		fmt.Fprintf(os.Stderr, "[Error] Processing '%s' failed: '%s'\n", filePath, err.Error())
		return err
	}
	if dump {
		metadata, _ := currentFile.FixMetadata()
		if !metadata {
			fmt.Fprintf(os.Stderr, "[Warning] Fix metadata for '%s' failed: '%s'\n", filePath, err.Error())
			return err
		}
		fmt.Printf("[Done] '%s' -> '%s'\n", filePath, currentFile.GetDumpFilePath())
	}
	return nil
}

func main() {
	var folderPath string
	showHelp := flag.BoolP("help", "h", false, "Display help message")
	showVersion := flag.BoolP("version", "v", false, "Display version information")
	flag.StringVarP(&folderPath, "dir", "d", "", "Process all files in the directory")
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
		fmt.Println("ncmdump version 1.5.0")
		os.Exit(0)
	}

	if folderPath != "" {
		// check if the folder exists
		info, err := os.Stat(folderPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "[Error] Unable to access directory '%s'", folderPath)
			os.Exit(1)
		}

		if !info.IsDir() {
			fmt.Fprintf(os.Stderr, "[Error] '%s' is not a directory", folderPath)
			os.Exit(1)
		}

		// dump files in the folder
		files, err := os.ReadDir(folderPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "[Error] Unable to read directory '%s'", folderPath)
			os.Exit(1)
		}

		for _, file := range files {
			if file.IsDir() {
				continue
			}

			filePath := filepath.Join(folderPath, file.Name())
			// skip if the extension is not .ncm
			if filePath[len(filePath)-4:] != ".ncm" {
				continue
			}
			err = processFile(filePath)
			if err != nil {
				continue
			}
		}
	} else {
		// dump file from args
		for _, filePath := range flag.Args() {
			// skip if the extension is not .ncm
			if filePath[len(filePath)-4:] != ".ncm" {
				continue
			}
			err := processFile(filePath)
			if err != nil {
				continue
			}
		}
	}

}
