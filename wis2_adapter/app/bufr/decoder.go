package bufr

import (
	"bytes"
	"fmt"
	"math"
	"strings"

	"wis2_adapter/bufr/tables"
)

const (
	maxMessageSize         = 16 * 1024 * 1024 // 16 MiB
	maxRecursionDepth      = 64
	maxExpandedDescriptors = 100_000
	maxReplicationCount    = 1_000
	maxSubsets             = 10_000
)

type decoderState struct {
	dataWidthChange      int
	scaleChange          int
	newRefWidth          int
	newRefValues         map[int]int64
	assocFieldWidth      int
	stringWidthOverride  int
	scaleRefWidthExtra   int
	bitmapRemaining      int
	bitmapBits           []bool
	skipNextLocal        bool
	localWidth           int
	recursionDepth       int
	totalDescriptorsRead int
	streamExhausted      bool
}

func isStringMissing(s string) bool {
	return strings.Trim(s, "\x00\xff ") == ""
}

func Decode(data []byte) ([]Message, []error) {
	if len(data) == 0 {
		return nil, []error{ErrTruncated{Detail: "empty input"}}
	}

	var messages []Message
	var errorsList []error

	pos := 0
	foundAny := false

	for pos < len(data) {
		idx := bytes.Index(data[pos:], []byte("BUFR"))
		if idx < 0 {
			break
		}
		foundAny = true
		startPos := pos + idx

		if startPos+8 > len(data) {
			messages = append(messages, Message{})
			errorsList = append(errorsList, ErrTruncated{Detail: "truncated Section 0 header"})
			break
		}

		totalLen := int(data[startPos+4])<<16 | int(data[startPos+5])<<8 | int(data[startPos+6])
		edition := int(data[startPos+7])

		if totalLen > maxMessageSize {
			messages = append(messages, Message{Edition: edition})
			errorsList = append(errorsList, ErrLimitExceeded{Detail: fmt.Sprintf("message length %d exceeds max %d", totalLen, maxMessageSize)})
			pos = startPos + 4
			continue
		}

		if totalLen < 16 {
			messages = append(messages, Message{Edition: edition})
			errorsList = append(errorsList, ErrInvalidBUFR{Detail: fmt.Sprintf("message length %d too small", totalLen)})
			pos = startPos + 4
			continue
		}

		if startPos+totalLen > len(data) {
			messages = append(messages, Message{Edition: edition})
			errorsList = append(errorsList, ErrTruncated{Detail: fmt.Sprintf("message length %d exceeds available stream %d", totalLen, len(data)-startPos)})
			break
		}

		endPos := startPos + totalLen
		if string(data[endPos-4:endPos]) != "7777" {
			messages = append(messages, Message{Edition: edition})
			errorsList = append(errorsList, ErrInvalidBUFR{Detail: "missing '7777' terminator"})
			pos = startPos + 4
			continue
		}

		msg, err := decodeSingleMessage(data[startPos:endPos])
		messages = append(messages, msg)
		errorsList = append(errorsList, err)

		pos = endPos
	}

	if !foundAny {
		return nil, []error{ErrNoBUFRFound{Detail: "no BUFR header found"}}
	}

	return messages, errorsList
}

func decodeSingleMessage(msgBytes []byte) (msg Message, err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("recovered from panic: %v", r)
		}
	}()

	if len(msgBytes) < 16 {
		return msg, ErrTruncated{Detail: "message shorter than 16 bytes"}
	}

	edition := int(msgBytes[7])
	if edition != 3 && edition != 4 {
		return msg, ErrInvalidBUFR{Detail: fmt.Sprintf("unsupported BUFR edition %d", edition)}
	}
	msg.Edition = edition

	// Section 1 starts at byte 8
	if len(msgBytes) < 11 {
		return msg, ErrTruncated{Detail: "truncated Section 1 length"}
	}
	s1Len := int(msgBytes[8])<<16 | int(msgBytes[9])<<8 | int(msgBytes[10])
	if s1Len < 8 || 8+s1Len > len(msgBytes)-4 {
		return msg, ErrTruncated{Detail: "invalid Section 1 length"}
	}

	var hasSec2 bool
	if edition == 4 {
		if s1Len < 22 {
			return msg, ErrInvalidBUFR{Detail: fmt.Sprintf("Section 1 edition 4 length %d too short", s1Len)}
		}
		msg.MasterTable = int(msgBytes[11])
		msg.Centre = int(msgBytes[12])<<8 | int(msgBytes[13])
		msg.SubCentre = int(msgBytes[14])<<8 | int(msgBytes[15])
		flags := msgBytes[17]
		hasSec2 = (flags & 0x80) != 0
		msg.DataCategory = int(msgBytes[18])
		msg.DataSubcategory = int(msgBytes[20])
		msg.MasterTableVersion = int(msgBytes[21])
		msg.LocalTableVersion = int(msgBytes[22])
	} else {
		// Edition 3
		if s1Len < 17 {
			return msg, ErrInvalidBUFR{Detail: fmt.Sprintf("Section 1 edition 3 length %d too short", s1Len)}
		}
		msg.MasterTable = int(msgBytes[11])
		msg.SubCentre = int(msgBytes[12])
		msg.Centre = int(msgBytes[13])
		flags := msgBytes[15]
		hasSec2 = (flags & 0x80) != 0
		msg.DataCategory = int(msgBytes[16])
		msg.DataSubcategory = int(msgBytes[17])
		msg.MasterTableVersion = int(msgBytes[18])
		msg.LocalTableVersion = int(msgBytes[19])
	}

	pos := 8 + s1Len
	if hasSec2 {
		if pos+3 > len(msgBytes)-4 {
			return msg, ErrTruncated{Detail: "truncated Section 2 header"}
		}
		s2Len := int(msgBytes[pos])<<16 | int(msgBytes[pos+1])<<8 | int(msgBytes[pos+2])
		if s2Len < 3 || pos+s2Len > len(msgBytes)-4 {
			return msg, ErrTruncated{Detail: "invalid Section 2 length"}
		}
		pos += s2Len
	}

	// Section 3
	if pos+7 > len(msgBytes)-4 {
		return msg, ErrTruncated{Detail: "truncated Section 3 header"}
	}
	s3Len := int(msgBytes[pos])<<16 | int(msgBytes[pos+1])<<8 | int(msgBytes[pos+2])
	if s3Len < 7 || pos+s3Len > len(msgBytes)-4 {
		return msg, ErrTruncated{Detail: "invalid Section 3 length"}
	}

	numSubsets := int(msgBytes[pos+4])<<8 | int(msgBytes[pos+5])
	if numSubsets <= 0 {
		return msg, ErrInvalidBUFR{Detail: fmt.Sprintf("invalid numberOfSubsets %d", numSubsets)}
	}
	if numSubsets > maxSubsets {
		return msg, ErrLimitExceeded{Detail: fmt.Sprintf("numberOfSubsets %d exceeds limit %d", numSubsets, maxSubsets)}
	}

	s3Flags := msgBytes[pos+6]
	compressed := (s3Flags & 0x40) != 0
	msg.Compressed = compressed

	numDesc := (s3Len - 7) / 2
	descriptors := make([]Descriptor, numDesc)
	for i := 0; i < numDesc; i++ {
		val := int(msgBytes[pos+7+i*2])<<8 | int(msgBytes[pos+8+i*2])
		descriptors[i] = Descriptor{
			F: (val >> 14) & 3,
			X: (val >> 8) & 0x3F,
			Y: val & 0xFF,
		}
	}
	pos += s3Len

	// Section 4
	if pos+4 > len(msgBytes)-4 {
		return msg, ErrTruncated{Detail: "truncated Section 4 header"}
	}
	s4Len := int(msgBytes[pos])<<16 | int(msgBytes[pos+1])<<8 | int(msgBytes[pos+2])
	if s4Len < 4 || pos+s4Len > len(msgBytes)-4 {
		return msg, ErrTruncated{Detail: "invalid Section 4 length"}
	}

	payload := msgBytes[pos+4 : pos+s4Len]
	bitReader := NewBitReader(payload)

	if compressed {
		subsets, err := decodeCompressed(descriptors, numSubsets, bitReader)
		if err != nil {
			return msg, err
		}
		msg.Subsets = subsets
	} else {
		subsets, err := decodeUncompressed(descriptors, numSubsets, bitReader)
		if err != nil {
			return msg, err
		}
		msg.Subsets = subsets
	}

	return msg, nil
}

func decodeUncompressed(descriptors []Descriptor, numSubsets int, bitReader *BitReader) ([][]Value, error) {
	subsets := make([][]Value, numSubsets)
	state := &decoderState{
		newRefValues: make(map[int]int64),
	}
	for s := 0; s < numSubsets; s++ {
		state.dataWidthChange = 0
		state.scaleChange = 0
		state.newRefWidth = 0
		state.assocFieldWidth = 0
		state.stringWidthOverride = 0
		state.scaleRefWidthExtra = 0
		state.bitmapRemaining = 0
		state.bitmapBits = nil
		state.skipNextLocal = false
		state.streamExhausted = false

		vals, err := decodeDescriptorsUncompressed(descriptors, bitReader, state)
		if err != nil {
			return nil, err
		}
		subsets[s] = vals
	}
	return subsets, nil
}

func decodeDescriptorsUncompressed(descriptors []Descriptor, bitReader *BitReader, state *decoderState) ([]Value, error) {
	state.recursionDepth++
	if state.recursionDepth > maxRecursionDepth {
		return nil, ErrLimitExceeded{Detail: fmt.Sprintf("recursion depth %d exceeded max %d", state.recursionDepth, maxRecursionDepth)}
	}
	defer func() {
		state.recursionDepth--
	}()

	var res []Value
	i := 0

	for i < len(descriptors) {
		state.totalDescriptorsRead++
		if state.totalDescriptorsRead > maxExpandedDescriptors {
			return nil, ErrLimitExceeded{Detail: fmt.Sprintf("expanded descriptors %d exceeded max %d", state.totalDescriptorsRead, maxExpandedDescriptors)}
		}

		desc := descriptors[i]

		if desc.IsLocal() {
			if state.skipNextLocal {
				state.skipNextLocal = false
				if !state.streamExhausted {
					if bitReader.BitsRemaining() < state.localWidth {
						state.streamExhausted = true
					} else {
						if err := bitReader.SkipBits(state.localWidth); err != nil {
							return nil, err
						}
					}
				}
				i++
				continue
			}
			return nil, ErrLocalDescriptor{Descriptor: desc}
		}

		switch desc.F {
		case 2:
			x, y := desc.X, desc.Y
			switch x {
			case 1:
				if y == 0 {
					state.dataWidthChange = 0
				} else {
					state.dataWidthChange = y - 128
				}
			case 2:
				if y == 0 {
					state.scaleChange = 0
				} else {
					state.scaleChange = y - 128
				}
			case 3:
				if y == 0 || y == 255 {
					state.newRefWidth = 0
					state.newRefValues = make(map[int]int64)
				} else {
					state.newRefWidth = y
					state.newRefValues = make(map[int]int64)
				}
			case 4:
				if y == 0 {
					state.assocFieldWidth = 0
				} else {
					state.assocFieldWidth = y
				}
			case 5:
				charCount := y
				var sPtr *string
				if !state.streamExhausted {
					if bitReader.BitsRemaining() < charCount*8 {
						state.streamExhausted = true
					} else {
						sVal, isMiss, err := bitReader.ReadString(charCount)
						if err != nil {
							return nil, err
						}
						if !isMiss && !isStringMissing(sVal) {
							trimmed := strings.TrimSpace(strings.Trim(sVal, "\x00"))
							sPtr = &trimmed
						}
					}
				}
				res = append(res, Value{
					Descriptor: desc,
					Name:       "Signify character",
					Unit:       "CCITT IA5",
					String:     sPtr,
					Value:      sPtr,
				})
			case 6:
				state.skipNextLocal = true
				state.localWidth = y
			case 7:
				if y == 0 {
					state.scaleRefWidthExtra = 0
				} else {
					state.scaleRefWidthExtra = y
				}
			case 8:
				if y == 0 {
					state.stringWidthOverride = 0
				} else {
					state.stringWidthOverride = y * 8
				}
			case 37:
				if y == 0 {
					state.bitmapRemaining = 0
					state.bitmapBits = nil
				} else {
					bits := make([]bool, y)
					for b := 0; b < y; b++ {
						if !state.streamExhausted {
							if bitReader.BitsRemaining() < 1 {
								state.streamExhausted = true
							} else {
								raw, err := bitReader.ReadBits(1)
								if err != nil {
									return nil, err
								}
								bits[b] = (raw == 1)
							}
						}
					}
					state.bitmapRemaining = y
					state.bitmapBits = bits
				}
			}
			i++

		case 3:
			seq, ok := tables.LookupD(desc.Code())
			if !ok {
				return nil, ErrUnknownDescriptor{Descriptor: desc}
			}
			nested := make([]Descriptor, len(seq))
			for idx, c := range seq {
				nested[idx] = Descriptor{F: c / 100000, X: (c % 100000) / 1000, Y: c % 1000}
			}
			vals, err := decodeDescriptorsUncompressed(nested, bitReader, state)
			if err != nil {
				return nil, err
			}
			res = append(res, vals...)
			i++

		case 1:
			repDescriptors := desc.X
			repCount := desc.Y
			if repDescriptors <= 0 {
				return nil, ErrInvalidBUFR{Detail: fmt.Sprintf("invalid replication descriptor count %d", repDescriptors)}
			}

			if repCount == 0 {
				i++
				if i >= len(descriptors) {
					return nil, ErrTruncated{Detail: "missing delayed replication factor"}
				}
				factorDesc := descriptors[i]
				entry, ok := tables.LookupB(factorDesc.Code())
				if !ok {
					return nil, ErrUnknownDescriptor{Descriptor: factorDesc}
				}
				effWidth := entry.Width + state.dataWidthChange
				if effWidth <= 0 || effWidth > 64 {
					return nil, ErrInvalidBUFR{Detail: fmt.Sprintf("invalid factor width %d", effWidth)}
				}
				if state.streamExhausted || bitReader.BitsRemaining() < effWidth {
					state.streamExhausted = true
					repCount = 0
				} else {
					rawBits, err := bitReader.ReadBits(effWidth)
					if err != nil {
						return nil, err
					}
					if factorDesc.Code() == 31000 {
						repCount = int(rawBits)
					} else {
						if IsAllOnes(rawBits, effWidth) {
							repCount = 0
						} else {
							repCount = int(rawBits)
						}
					}
				}
				fVal := float64(repCount)
				res = append(res, Value{
					Descriptor: factorDesc,
					Name:       entry.Name,
					Unit:       entry.Unit,
					Float:      &fVal,
					Value:      &fVal,
				})
			}

			if repCount > maxReplicationCount {
				return nil, ErrLimitExceeded{Detail: fmt.Sprintf("replication count %d exceeds maximum %d", repCount, maxReplicationCount)}
			}

			if i+1+repDescriptors > len(descriptors) {
				return nil, ErrTruncated{Detail: "descriptor stream ended before replication block"}
			}
			block := descriptors[i+1 : i+1+repDescriptors]
			i += 1 + repDescriptors

			for r := 0; r < repCount; r++ {
				vals, err := decodeDescriptorsUncompressed(block, bitReader, state)
				if err != nil {
					return nil, err
				}
				res = append(res, vals...)
			}

		case 0:
			entry, ok := tables.LookupB(desc.Code())
			if !ok {
				return nil, ErrUnknownDescriptor{Descriptor: desc}
			}

			if state.bitmapRemaining > 0 {
				bitPresent := state.bitmapBits[len(state.bitmapBits)-state.bitmapRemaining]
				state.bitmapRemaining--
				if !bitPresent {
					res = append(res, Value{
						Descriptor: desc,
						Name:       entry.Name,
						Unit:       entry.Unit,
					})
					i++
					continue
				}
			}

			if state.assocFieldWidth > 0 && !state.streamExhausted {
				if bitReader.BitsRemaining() < state.assocFieldWidth {
					state.streamExhausted = true
				} else {
					if err := bitReader.SkipBits(state.assocFieldWidth); err != nil {
						return nil, err
					}
				}
			}

			effRef := entry.Reference
			if state.newRefWidth > 0 && !state.streamExhausted {
				if bitReader.BitsRemaining() < state.newRefWidth {
					state.streamExhausted = true
				} else {
					newRef, err := bitReader.ReadSignedBits(state.newRefWidth)
					if err != nil {
						return nil, err
					}
					effRef = newRef
					state.newRefValues[desc.Code()] = newRef
				}
			} else if state.newRefValues != nil {
				if prevRef, exists := state.newRefValues[desc.Code()]; exists {
					effRef = prevRef
				}
			}

			effScale := entry.Scale + state.scaleChange + state.scaleRefWidthExtra
			if state.scaleRefWidthExtra > 0 {
				effRef = effRef * int64(math.Pow10(state.scaleRefWidthExtra))
			}

			effWidth := entry.Width
			if entry.Unit == "CCITT IA5" {
				if state.stringWidthOverride > 0 {
					effWidth = state.stringWidthOverride
				}
				charCount := effWidth / 8
				var sPtr *string
				if !state.streamExhausted {
					if bitReader.BitsRemaining() < effWidth {
						state.streamExhausted = true
					} else {
						sVal, isMiss, err := bitReader.ReadString(charCount)
						if err != nil {
							return nil, err
						}
						if !isMiss && !isStringMissing(sVal) {
							trimmed := strings.TrimSpace(strings.Trim(sVal, "\x00"))
							sPtr = &trimmed
						}
					}
				}
				res = append(res, Value{
					Descriptor: desc,
					Name:       entry.Name,
					Unit:       entry.Unit,
					String:     sPtr,
					Value:      sPtr,
				})
			} else {
				effWidth += state.dataWidthChange
				if state.scaleRefWidthExtra > 0 {
					effWidth += (10*state.scaleRefWidthExtra + 2) / 3
				}
				if effWidth <= 0 || effWidth > 64 {
					return nil, ErrInvalidBUFR{Detail: fmt.Sprintf("invalid element width %d", effWidth)}
				}
				var fPtr *float64
				if !state.streamExhausted {
					if bitReader.BitsRemaining() < effWidth {
						state.streamExhausted = true
					} else {
						rawBits, err := bitReader.ReadBits(effWidth)
						if err != nil {
							return nil, err
						}
						if !IsAllOnes(rawBits, effWidth) {
							computed := (float64(rawBits) + float64(effRef)) * math.Pow10(-effScale)
							fPtr = &computed
						}
					}
				}
				res = append(res, Value{
					Descriptor: desc,
					Name:       entry.Name,
					Unit:       entry.Unit,
					Float:      fPtr,
					Value:      fPtr,
				})
			}
			i++
		}
	}

	return res, nil
}

func decodeCompressed(descriptors []Descriptor, numSubsets int, bitReader *BitReader) ([][]Value, error) {
	subsets := make([][]Value, numSubsets)
	state := &decoderState{
		newRefValues: make(map[int]int64),
	}
	if err := decodeDescriptorsCompressed(descriptors, bitReader, state, subsets); err != nil {
		return nil, err
	}
	return subsets, nil
}

func decodeDescriptorsCompressed(descriptors []Descriptor, bitReader *BitReader, state *decoderState, subsets [][]Value) error {
	state.recursionDepth++
	if state.recursionDepth > maxRecursionDepth {
		return ErrLimitExceeded{Detail: fmt.Sprintf("recursion depth %d exceeded max %d", state.recursionDepth, maxRecursionDepth)}
	}
	defer func() {
		state.recursionDepth--
	}()

	numSubsets := len(subsets)
	i := 0

	for i < len(descriptors) {
		inc := numSubsets
		if inc < 1 {
			inc = 1
		}
		state.totalDescriptorsRead += inc
		if state.totalDescriptorsRead > maxExpandedDescriptors {
			return ErrLimitExceeded{Detail: fmt.Sprintf("expanded descriptors %d exceeded max %d", state.totalDescriptorsRead, maxExpandedDescriptors)}
		}

		desc := descriptors[i]

		if desc.IsLocal() {
			if state.skipNextLocal {
				state.skipNextLocal = false
				if !state.streamExhausted {
					if bitReader.BitsRemaining() < state.localWidth {
						state.streamExhausted = true
					} else {
						if err := bitReader.SkipBits(state.localWidth); err != nil {
							return err
						}
					}
				}
				i++
				continue
			}
			return ErrLocalDescriptor{Descriptor: desc}
		}

		switch desc.F {
		case 2:
			x, y := desc.X, desc.Y
			switch x {
			case 1:
				if y == 0 {
					state.dataWidthChange = 0
				} else {
					state.dataWidthChange = y - 128
				}
			case 2:
				if y == 0 {
					state.scaleChange = 0
				} else {
					state.scaleChange = y - 128
				}
			case 3:
				if y == 0 || y == 255 {
					state.newRefWidth = 0
					state.newRefValues = make(map[int]int64)
				} else {
					state.newRefWidth = y
					state.newRefValues = make(map[int]int64)
				}
			case 4:
				if y == 0 {
					state.assocFieldWidth = 0
				} else {
					state.assocFieldWidth = y
				}
			case 5:
				charCount := y
				if state.streamExhausted || bitReader.BitsRemaining() < charCount*8+6 {
					state.streamExhausted = true
					for s := 0; s < numSubsets; s++ {
						subsets[s] = append(subsets[s], Value{
							Descriptor: desc,
							Name:       "Signify character",
							Unit:       "CCITT IA5",
						})
					}
					i++
					continue
				}
				refStr, isRefMiss, err := bitReader.ReadString(charCount)
				if err != nil {
					return err
				}
				nbincBits, err := bitReader.ReadBits(6)
				if err != nil {
					return err
				}
				nbinc := int(nbincBits)

				if nbinc == 0 {
					var sPtr *string
					if !isRefMiss && !isStringMissing(refStr) {
						trimmed := strings.TrimSpace(strings.Trim(refStr, "\x00"))
						sPtr = &trimmed
					}
					for s := 0; s < numSubsets; s++ {
						subsets[s] = append(subsets[s], Value{
							Descriptor: desc,
							Name:       "Signify character",
							Unit:       "CCITT IA5",
							String:     sPtr,
							Value:      sPtr,
						})
					}
				} else {
					for s := 0; s < numSubsets; s++ {
						var sPtr *string
						if !state.streamExhausted && bitReader.BitsRemaining() >= nbinc*8 {
							incStr, isIncMiss, err := bitReader.ReadString(nbinc)
							if err != nil {
								return err
							}
							if !isIncMiss && !isRefMiss && !isStringMissing(incStr) {
								trimmed := strings.TrimSpace(strings.Trim(incStr, "\x00"))
								sPtr = &trimmed
							}
						} else {
							state.streamExhausted = true
						}
						subsets[s] = append(subsets[s], Value{
							Descriptor: desc,
							Name:       "Signify character",
							Unit:       "CCITT IA5",
							String:     sPtr,
							Value:      sPtr,
						})
					}
				}
			case 6:
				state.skipNextLocal = true
				state.localWidth = y
			case 7:
				if y == 0 {
					state.scaleRefWidthExtra = 0
				} else {
					state.scaleRefWidthExtra = y
				}
			case 8:
				if y == 0 {
					state.stringWidthOverride = 0
				} else {
					state.stringWidthOverride = y * 8
				}
			}
			i++

		case 3:
			seq, ok := tables.LookupD(desc.Code())
			if !ok {
				return ErrUnknownDescriptor{Descriptor: desc}
			}
			nested := make([]Descriptor, len(seq))
			for idx, c := range seq {
				nested[idx] = Descriptor{F: c / 100000, X: (c % 100000) / 1000, Y: c % 1000}
			}
			if err := decodeDescriptorsCompressed(nested, bitReader, state, subsets); err != nil {
				return err
			}
			i++

		case 1:
			repDescriptors := desc.X
			repCount := desc.Y
			if repDescriptors <= 0 {
				return ErrInvalidBUFR{Detail: fmt.Sprintf("invalid replication descriptor count %d", repDescriptors)}
			}

			if repCount == 0 {
				i++
				if i >= len(descriptors) {
					return ErrTruncated{Detail: "missing delayed replication factor"}
				}
				factorDesc := descriptors[i]
				entry, ok := tables.LookupB(factorDesc.Code())
				if !ok {
					return ErrUnknownDescriptor{Descriptor: factorDesc}
				}
				effWidth := entry.Width + state.dataWidthChange
				if state.streamExhausted || bitReader.BitsRemaining() < effWidth+6 {
					state.streamExhausted = true
					repCount = 0
				} else {
					refBits, err := bitReader.ReadBits(effWidth)
					if err != nil {
						return err
					}
					nbincBits, err := bitReader.ReadBits(6)
					if err != nil {
						return err
					}
					nbinc := int(nbincBits)
					if factorDesc.Code() == 31000 {
						repCount = int(refBits)
					} else {
						if IsAllOnes(refBits, effWidth) {
							repCount = 0
						} else {
							repCount = int(refBits)
						}
					}
					if nbinc > 0 {
						for s := 0; s < numSubsets; s++ {
							incBits, err := bitReader.ReadBits(nbinc)
							if err != nil {
								return err
							}
							_ = incBits
						}
					}
				}
				fVal := float64(repCount)
				for s := 0; s < numSubsets; s++ {
					subsets[s] = append(subsets[s], Value{
						Descriptor: factorDesc,
						Name:       entry.Name,
						Unit:       entry.Unit,
						Float:      &fVal,
						Value:      &fVal,
					})
				}
			}

			if repCount > maxReplicationCount {
				return ErrLimitExceeded{Detail: fmt.Sprintf("replication count %d exceeds maximum %d", repCount, maxReplicationCount)}
			}

			if i+1+repDescriptors > len(descriptors) {
				return ErrTruncated{Detail: "descriptor stream ended before replication block"}
			}
			block := descriptors[i+1 : i+1+repDescriptors]
			i += 1 + repDescriptors

			for r := 0; r < repCount; r++ {
				if err := decodeDescriptorsCompressed(block, bitReader, state, subsets); err != nil {
					return err
				}
			}

		case 0:
			entry, ok := tables.LookupB(desc.Code())
			if !ok {
				return ErrUnknownDescriptor{Descriptor: desc}
			}

			effRef := entry.Reference
			effScale := entry.Scale + state.scaleChange + state.scaleRefWidthExtra
			if state.scaleRefWidthExtra > 0 {
				effRef = effRef * int64(math.Pow10(state.scaleRefWidthExtra))
			}

			effWidth := entry.Width
			if entry.Unit == "CCITT IA5" {
				if state.stringWidthOverride > 0 {
					effWidth = state.stringWidthOverride
				}
				charCount := effWidth / 8
				if state.streamExhausted || bitReader.BitsRemaining() < effWidth+6 {
					state.streamExhausted = true
					for s := 0; s < numSubsets; s++ {
						subsets[s] = append(subsets[s], Value{
							Descriptor: desc,
							Name:       entry.Name,
							Unit:       entry.Unit,
						})
					}
					i++
					continue
				}

				refStr, isRefMiss, err := bitReader.ReadString(charCount)
				if err != nil {
					return err
				}
				nbincBits, err := bitReader.ReadBits(6)
				if err != nil {
					return err
				}
				nbinc := int(nbincBits)

				if nbinc == 0 {
					var sPtr *string
					if !isRefMiss && !isStringMissing(refStr) {
						trimmed := strings.TrimSpace(strings.Trim(refStr, "\x00"))
						sPtr = &trimmed
					}
					for s := 0; s < numSubsets; s++ {
						subsets[s] = append(subsets[s], Value{
							Descriptor: desc,
							Name:       entry.Name,
							Unit:       entry.Unit,
							String:     sPtr,
							Value:      sPtr,
						})
					}
				} else {
					for s := 0; s < numSubsets; s++ {
						var sPtr *string
						if !state.streamExhausted && bitReader.BitsRemaining() >= nbinc*8 {
							incStr, isIncMiss, err := bitReader.ReadString(nbinc)
							if err != nil {
								return err
							}
							if !isIncMiss && !isRefMiss && !isStringMissing(incStr) {
								trimmed := strings.TrimSpace(strings.Trim(incStr, "\x00"))
								sPtr = &trimmed
							}
						} else {
							state.streamExhausted = true
						}
						subsets[s] = append(subsets[s], Value{
							Descriptor: desc,
							Name:       entry.Name,
							Unit:       entry.Unit,
							String:     sPtr,
							Value:      sPtr,
						})
					}
				}
			} else {
				effWidth += state.dataWidthChange
				if state.scaleRefWidthExtra > 0 {
					effWidth += (10*state.scaleRefWidthExtra + 2) / 3
				}
				if effWidth <= 0 || effWidth > 64 {
					return ErrInvalidBUFR{Detail: fmt.Sprintf("invalid element width %d", effWidth)}
				}
				if state.streamExhausted || bitReader.BitsRemaining() < effWidth+6 {
					state.streamExhausted = true
					for s := 0; s < numSubsets; s++ {
						subsets[s] = append(subsets[s], Value{
							Descriptor: desc,
							Name:       entry.Name,
							Unit:       entry.Unit,
						})
					}
					i++
					continue
				}

				refBits, err := bitReader.ReadBits(effWidth)
				if err != nil {
					return err
				}
				isRefMiss := IsAllOnes(refBits, effWidth)

				nbincBits, err := bitReader.ReadBits(6)
				if err != nil {
					return err
				}
				nbinc := int(nbincBits)

				if nbinc == 0 {
					var fPtr *float64
					if !isRefMiss {
						computed := (float64(refBits) + float64(effRef)) * math.Pow10(-effScale)
						fPtr = &computed
					}
					for s := 0; s < numSubsets; s++ {
						subsets[s] = append(subsets[s], Value{
							Descriptor: desc,
							Name:       entry.Name,
							Unit:       entry.Unit,
							Float:      fPtr,
							Value:      fPtr,
						})
					}
				} else {
					for s := 0; s < numSubsets; s++ {
						var fPtr *float64
						if !state.streamExhausted && bitReader.BitsRemaining() >= nbinc {
							incBits, err := bitReader.ReadBits(nbinc)
							if err != nil {
								return err
							}
							isIncMiss := IsAllOnes(incBits, nbinc)
							if !isRefMiss && !isIncMiss {
								computed := (float64(refBits+incBits) + float64(effRef)) * math.Pow10(-effScale)
								fPtr = &computed
							}
						} else {
							state.streamExhausted = true
						}
						subsets[s] = append(subsets[s], Value{
							Descriptor: desc,
							Name:       entry.Name,
							Unit:       entry.Unit,
							Float:      fPtr,
							Value:      fPtr,
						})
					}
				}
			}
			i++
		}
	}

	return nil
}
