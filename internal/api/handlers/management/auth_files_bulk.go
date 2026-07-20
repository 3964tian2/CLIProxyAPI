package management

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const (
	maxAuthUploadFiles              = 10000
	maxAuthArchiveUncompressedFile  = 8 << 20
	maxAuthArchiveUncompressedTotal = 512 << 20
)

type authUploadFailure struct {
	Name  string `json:"name"`
	Error string `json:"error"`
}

type authFileImportResult struct {
	Files  []string
	Failed []authUploadFailure
}

func (r *authFileImportResult) add(ctx context.Context, h *Handler, name string, data []byte, reserved map[string]struct{}) {
	name = filepath.Base(strings.TrimSpace(name))
	if !strings.HasSuffix(strings.ToLower(name), ".json") || isUnsafeAuthFileName(name) {
		r.Failed = append(r.Failed, authUploadFailure{Name: name, Error: "file must be a safe .json credential"})
		return
	}
	if len(data) == 0 || len(data) > maxAuthArchiveUncompressedFile {
		r.Failed = append(r.Failed, authUploadFailure{Name: name, Error: "credential size is outside the allowed limit"})
		return
	}
	name = reserveImportedAuthFileName(h.cfg.AuthDir, name, reserved)
	if err := h.writeAuthFile(ctx, name, data); err != nil {
		r.Failed = append(r.Failed, authUploadFailure{Name: name, Error: err.Error()})
		return
	}
	r.Files = append(r.Files, name)
}

func reserveImportedAuthFileName(dir, name string, reserved map[string]struct{}) string {
	ext := filepath.Ext(name)
	base := strings.TrimSuffix(name, ext)
	for n := 0; ; n++ {
		candidate := name
		if n > 0 {
			candidate = fmt.Sprintf("%s-%d%s", base, n, ext)
		}
		key := strings.ToLower(candidate)
		if _, exists := reserved[key]; exists {
			continue
		}
		if _, err := os.Stat(filepath.Join(dir, candidate)); err == nil {
			continue
		}
		reserved[key] = struct{}{}
		return candidate
	}
}

func (h *Handler) importAuthArchive(ctx context.Context, filename string, raw []byte) authFileImportResult {
	result := authFileImportResult{Files: make([]string, 0), Failed: make([]authUploadFailure, 0)}
	reserved := make(map[string]struct{})
	add := func(name string, reader io.Reader, size int64) bool {
		if len(result.Files)+len(result.Failed) >= maxAuthUploadFiles {
			result.Failed = append(result.Failed, authUploadFailure{Name: name, Error: "archive contains too many credentials"})
			return false
		}
		if size < 0 || size > maxAuthArchiveUncompressedFile {
			result.Failed = append(result.Failed, authUploadFailure{Name: name, Error: "credential size is outside the allowed limit"})
			return true
		}
		data, err := io.ReadAll(io.LimitReader(reader, maxAuthArchiveUncompressedFile+1))
		if err != nil || len(data) > maxAuthArchiveUncompressedFile {
			result.Failed = append(result.Failed, authUploadFailure{Name: name, Error: "failed to read credential within allowed limit"})
			return true
		}
		result.add(ctx, h, name, data, reserved)
		return true
	}

	lower := strings.ToLower(strings.TrimSpace(filename))
	if strings.HasSuffix(lower, ".zip") {
		zr, err := zip.NewReader(bytes.NewReader(raw), int64(len(raw)))
		if err != nil {
			result.Failed = append(result.Failed, authUploadFailure{Name: filename, Error: "invalid zip archive"})
			return result
		}
		var total int64
		for _, entry := range zr.File {
			if entry.FileInfo().IsDir() || !strings.HasSuffix(strings.ToLower(entry.Name), ".json") {
				continue
			}
			total += int64(entry.UncompressedSize64)
			if total > maxAuthArchiveUncompressedTotal {
				result.Failed = append(result.Failed, authUploadFailure{Name: entry.Name, Error: "archive exceeds total extraction limit"})
				break
			}
			reader, err := entry.Open()
			if err != nil {
				result.Failed = append(result.Failed, authUploadFailure{Name: entry.Name, Error: "failed to open archive entry"})
				continue
			}
			keep := add(entry.Name, reader, int64(entry.UncompressedSize64))
			_ = reader.Close()
			if !keep {
				break
			}
		}
		return result
	}

	reader := io.Reader(bytes.NewReader(raw))
	if strings.HasSuffix(lower, ".tar.gz") || strings.HasSuffix(lower, ".tgz") {
		gz, err := gzip.NewReader(reader)
		if err != nil {
			result.Failed = append(result.Failed, authUploadFailure{Name: filename, Error: "invalid gzip archive"})
			return result
		}
		defer gz.Close()
		reader = gz
	}
	if !strings.HasSuffix(lower, ".tar") && !strings.HasSuffix(lower, ".tar.gz") && !strings.HasSuffix(lower, ".tgz") {
		result.Failed = append(result.Failed, authUploadFailure{Name: filename, Error: "unsupported archive type"})
		return result
	}
	tr := tar.NewReader(reader)
	var total int64
	for {
		header, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			result.Failed = append(result.Failed, authUploadFailure{Name: filename, Error: "invalid tar archive"})
			break
		}
		if header.FileInfo().IsDir() || !strings.HasSuffix(strings.ToLower(header.Name), ".json") {
			continue
		}
		total += header.Size
		if total > maxAuthArchiveUncompressedTotal {
			result.Failed = append(result.Failed, authUploadFailure{Name: header.Name, Error: "archive exceeds total extraction limit"})
			break
		}
		if !add(header.Name, tr, header.Size) {
			break
		}
	}
	return result
}
