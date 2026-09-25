package bufr

import (
	"errors"
	"fmt"
	"io"
)

type BitReader struct {
	data   []byte
	bitPos int
}

func NewBitReader(data []byte) *BitReader {
	return &BitReader{
		data:   data,
		bitPos: 0,
	}
}

func (b *BitReader) BitPos() int {
	return b.bitPos
}

func (b *BitReader) BitsRemaining() int {
	rem := len(b.data)*8 - b.bitPos
	if rem < 0 {
		return 0
	}
	return rem
}

func (b *BitReader) SkipBits(n int) error {
	if n < 0 {
		return errors.New("negative bit count")
	}
	if b.bitPos+n > len(b.data)*8 {
		return io.ErrUnexpectedEOF
	}
	b.bitPos += n
	return nil
}

func (b *BitReader) ReadBits(n int) (uint64, error) {
	if n == 0 {
		return 0, nil
	}
	if n < 0 || n > 64 {
		return 0, fmt.Errorf("invalid bit count %d", n)
	}
	if b.bitPos+n > len(b.data)*8 {
		return 0, io.ErrUnexpectedEOF
	}

	var res uint64
	for n > 0 {
		byteIdx := b.bitPos / 8
		bitOffset := b.bitPos % 8
		bitsAvail := 8 - bitOffset
		take := n
		if take > bitsAvail {
			take = bitsAvail
		}

		shift := bitsAvail - take
		mask := byte(((1 << take) - 1) << shift)
		chunk := uint64((b.data[byteIdx] & mask) >> shift)

		res = (res << take) | chunk
		b.bitPos += take
		n -= take
	}
	return res, nil
}

func (b *BitReader) ReadSignedBits(n int) (int64, error) {
	if n <= 1 {
		return 0, nil
	}
	raw, err := b.ReadBits(n)
	if err != nil {
		return 0, err
	}
	signBit := (raw >> (n - 1)) & 1
	magMask := (uint64(1) << (n - 1)) - 1
	mag := int64(raw & magMask)
	if signBit == 1 {
		return -mag, nil
	}
	return mag, nil
}

func (b *BitReader) ReadString(charCount int) (string, bool, error) {
	if charCount <= 0 {
		return "", false, nil
	}
	buf := make([]byte, charCount)
	allFF := true
	for i := 0; i < charCount; i++ {
		val, err := b.ReadBits(8)
		if err != nil {
			return "", false, err
		}
		c := byte(val)
		buf[i] = c
		if c != 0xFF {
			allFF = false
		}
	}
	if allFF {
		return "", true, nil
	}
	return string(buf), false, nil
}

func IsAllOnes(val uint64, width int) bool {
	if width <= 0 {
		return false
	}
	if width >= 64 {
		return val == ^uint64(0)
	}
	return val == (uint64(1)<<width)-1
}
