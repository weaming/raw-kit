package utils

import (
	"path/filepath"
	"strings"
)

func ReplaceExtension(filepathStr, newExt string) string {
	ext := filepath.Ext(filepathStr)
	return strings.TrimSuffix(filepathStr, ext) + newExt
}
