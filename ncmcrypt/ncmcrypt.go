package ncmcrypt

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"github.com/bogem/id3v2/v2"
	"github.com/go-flac/flacpicture"
	"github.com/go-flac/go-flac"
	"io"
	"ncmdump/utils"
	"net/http"
	"os"
	"path/filepath"
)

type NcmFormat = string

const (
	Mp3 NcmFormat = "mp3"
)
const (
	Flac NcmFormat = "flac"
)

type NeteaseCloudMusic struct {
	sCoreKey   [17]byte
	sModifyKey [17]byte
	mPng       [8]byte

	mFilePath string

	mDumpFilePath string
	mFormat       NcmFormat
	mImageData    []byte
	mFileStream   *os.File
	mKeyBox       [256]byte
	mMetadata     *NeteaseClousMusicMetadata
	mAlbumPicUrl  string
}

func (ncm *NeteaseCloudMusic) read(buffer *[]byte, size int) int {
	if len(*buffer) < size {
		*buffer = make([]byte, size)
	}
	res, err := ncm.mFileStream.Read(*buffer)
	if err != nil {
		return 0
	}
	return res
}

func (ncm *NeteaseCloudMusic) openFile() bool {
	file, err := os.Open(ncm.mFilePath)
	if err != nil {
		return false
	}
	ncm.mFileStream = file
	return true
}

func (ncm *NeteaseCloudMusic) isNcmFile() bool {
	header := make([]byte, 4)

	// check magic header 4E455443 4D414446
	if ncm.read(&header, 4) != 4 {
		return false
	}
	if int(binary.LittleEndian.Uint32(header)) != 0x4E455443 {
		return false
	}
	if ncm.read(&header, 4) != 4 {
		return false
	}

	if int(binary.LittleEndian.Uint32(header)) != 0x4D414446 {
		return false
	}

	return true
}

func (ncm *NeteaseCloudMusic) buildKeyBox(key []byte, keyLen int) {
	for i := 0; i < 256; i++ {
		ncm.mKeyBox[i] = byte(i)
	}

	var swap uint8 = 0
	var c uint8 = 0
	var lastByte uint8 = 0
	var keyOffset uint8 = 0

	for i := 0; i < 256; i++ {
		swap = ncm.mKeyBox[i]
		c = (swap + lastByte + key[keyOffset]) & 0xff
		keyOffset++
		if int(keyOffset) >= keyLen {
			keyOffset = 0
		}
		ncm.mKeyBox[i] = ncm.mKeyBox[c]
		ncm.mKeyBox[c] = swap
		lastByte = c
	}
}

func (ncm *NeteaseCloudMusic) mimeType() string {
	if bytes.HasPrefix(ncm.mImageData, ncm.mPng[:]) {
		return "image/png"
	}
	return "image/jpeg"
}

func (ncm *NeteaseCloudMusic) Dump(targetDir string) (bool, error) {
	ncm.mDumpFilePath = ncm.mFilePath
	var outputStream *os.File

	buffer := make([]byte, 0x8000)
	findFormatFlag := false

	for {
		n := ncm.read(&buffer, len(buffer))

		if n == 0 {
			break
		}

		for i := 0; i < n; i++ {
			j := (i + 1) & 0xff
			buffer[i] ^= ncm.mKeyBox[(ncm.mKeyBox[j]+ncm.mKeyBox[(int(ncm.mKeyBox[j])+j)&0xff])&0xff]
		}

		if !findFormatFlag {
			if buffer[0] == 0x49 && buffer[1] == 0x44 && buffer[2] == 0x33 {
				ncm.mFormat = Mp3
				ncm.mDumpFilePath = utils.ReplaceExtension(ncm.mDumpFilePath, ".mp3")
			} else {
				ncm.mFormat = Flac
				ncm.mDumpFilePath = utils.ReplaceExtension(ncm.mDumpFilePath, ".flac")
			}
			if targetDir != "" { // change save dir
				ncm.mDumpFilePath = filepath.Join(targetDir, filepath.Base(ncm.mDumpFilePath))
			}
			findFormatFlag = true

			output, err := os.Create(ncm.mDumpFilePath)
			if err != nil {
				return false, fmt.Errorf("create output file failed")
			}
			outputStream = output
		}

		outputStream.Write(buffer)
	}

	outputStream.Close()
	return true, nil
}

func (ncm *NeteaseCloudMusic) FixMetadata() (bool, error) {
	if ncm.mFormat == Mp3 {
		audioFile, err := id3v2.Open(ncm.mDumpFilePath, id3v2.Options{Parse: true})
		if err != nil {
			return false, err
		}
		defer audioFile.Close()
		audioFile.SetTitle(ncm.mMetadata.mName)
		audioFile.SetArtist(ncm.mMetadata.mArtist)
		audioFile.SetAlbum(ncm.mMetadata.mAlbum)

		if len(ncm.mImageData) > 0 {
			pic := id3v2.PictureFrame{
				Encoding:    id3v2.EncodingUTF8,
				MimeType:    ncm.mimeType(),
				PictureType: id3v2.PTFrontCover,
				Description: "",
				Picture:     ncm.mImageData,
			}
			audioFile.AddAttachedPicture(pic)
		}

		err = audioFile.Save()
		if err != nil {
			return false, err
		}
	} else if ncm.mFormat == Flac {
		audioFile, err := flac.ParseFile(ncm.mDumpFilePath)
		if err != nil {
			return false, err
		}
		if len(ncm.mImageData) > 0 {
			pic, err := flacpicture.NewFromImageData(flacpicture.PictureTypeFrontCover, "",
				ncm.mImageData, ncm.mimeType())
			if err != nil {
				return false, err
			}
			pictureMeta := pic.Marshal()
			audioFile.Meta = append(audioFile.Meta, &pictureMeta)
		}
		generalMeta := &flac.MetaDataBlock{
			Type: flac.VorbisComment,
			Data: []byte(fmt.Sprintf("title=%s\nartist=%s\nalbum=%s", ncm.mMetadata.mName, ncm.mMetadata.mArtist, ncm.mMetadata.mAlbum)),
		}
		audioFile.Meta = append(audioFile.Meta, generalMeta)
		err = audioFile.Save(ncm.mDumpFilePath)
		if err != nil {
			return false, err
		}
	}
	return true, nil
}

func (ncm *NeteaseCloudMusic) GetDumpFilePath() string {
	return ncm.mDumpFilePath
}

func NewNeteaseCloudMusic(filePath string) (*NeteaseCloudMusic, error) {
	ncm := &NeteaseCloudMusic{
		sCoreKey:   [17]byte{0x68, 0x7A, 0x48, 0x52, 0x41, 0x6D, 0x73, 0x6F, 0x35, 0x6B, 0x49, 0x6E, 0x62, 0x61, 0x78, 0x57, 0},
		sModifyKey: [17]byte{0x23, 0x31, 0x34, 0x6C, 0x6A, 0x6B, 0x5F, 0x21, 0x5C, 0x5D, 0x26, 0x30, 0x55, 0x3C, 0x27, 0x28, 0},
		mPng:       [8]byte{0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A},

		mFilePath: filePath,
	}

	if !ncm.openFile() {
		return nil, fmt.Errorf("open file failed")
	}

	if !ncm.isNcmFile() {
		return nil, fmt.Errorf("not a ncm file")
	}

	// actually this 2 bytes is the version, now we just skip it
	if _, err := ncm.mFileStream.Seek(2, 1); err != nil {
		return nil, fmt.Errorf("seek version failed")
	}

	// the length of the RC4 key, encrypted by AES128
	n := make([]byte, 4)

	if ncm.read(&n, len(n)) != 4 {
		return nil, fmt.Errorf("read key len failed")
	}

	keyLen := int(binary.LittleEndian.Uint32(n))

	keydata := make([]byte, keyLen)
	ncm.read(&keydata, keyLen)

	for i := range keydata {
		keydata[i] ^= 0x64
	}

	mKeyData, err := utils.AesEcbDecrypt(ncm.sCoreKey[:16], keydata)

	if err != nil {
		return nil, fmt.Errorf("decrypt key failed")
	}

	// build the key box
	ncm.buildKeyBox(mKeyData[17:], len(mKeyData)-17)

	if ncm.read(&n, len(n)) != 4 {
		return nil, fmt.Errorf("read metadata len failed")
	}

	metadataLen := int(binary.LittleEndian.Uint32(n))

	if metadataLen <= 0 {
		// process meta here
		ncm.mMetadata = nil
	} else {
		// read metadata
		modifyData := make([]byte, metadataLen)
		ncm.read(&modifyData, metadataLen)

		for i := range modifyData {
			modifyData[i] ^= 0x63
		}

		// escape `163 key(Don't modify):`
		swapModifyData := string(modifyData[22:])

		modifyOutData, err := base64.StdEncoding.DecodeString(swapModifyData)
		if err != nil {
			panic("base64 decode modify data failed")
		}

		modifyDecryptData, err := utils.AesEcbDecrypt(ncm.sModifyKey[:16], modifyOutData)

		if err != nil {
			panic("decrypt modify data failed")
		}

		// escape `music:`
		mMetadataString := string(modifyDecryptData[6:])

		// extract the album pic url
		ncm.mAlbumPicUrl = GetAlbumPicUrl(mMetadataString)

		ncm.mMetadata = NewNeteaseCloudMusicMetadata(mMetadataString)
	}

	// skip the 5 bytes gap
	if _, err := ncm.mFileStream.Seek(5, 1); err != nil {
		return nil, fmt.Errorf("seek gap failed")
	}

	// read the cover frame
	coverFrameLen := make([]byte, 4)

	if ncm.read(&coverFrameLen, len(coverFrameLen)) != 4 {
		return nil, fmt.Errorf("read cover frame len failed")
	}

	if ncm.read(&n, len(n)) != 4 {
		return nil, fmt.Errorf("read cover frame data len failed")
	}

	coverFrameLenInt := int(binary.LittleEndian.Uint32(coverFrameLen))
	coverFrameDataLen := int(binary.LittleEndian.Uint32(n))

	if coverFrameDataLen > 0 {
		ncm.read(&ncm.mImageData, coverFrameDataLen)
	} else {
		// get the album pic from url
		resp, err := http.Get(ncm.mAlbumPicUrl)
		if err != nil {
		}
		if resp != nil {
			if resp.StatusCode == http.StatusOK {
				bodyBytes, err := io.ReadAll(resp.Body)
				if err != nil {
				}
				ncm.mImageData = bodyBytes
			}
		}
	}

	ncm.mFileStream.Seek(int64(coverFrameLenInt)-int64(coverFrameDataLen), 1)

	return ncm, nil
}
