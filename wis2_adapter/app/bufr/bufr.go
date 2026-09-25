package bufr

import (
	"fmt"
)

type Descriptor struct {
	F int
	X int
	Y int
}

func NewDescriptor(code int) Descriptor {
	return Descriptor{
		F: code / 100000,
		X: (code % 100000) / 1000,
		Y: code % 1000,
	}
}

func (d Descriptor) Code() int {
	return d.F*100000 + d.X*1000 + d.Y
}

func (d Descriptor) String() string {
	return fmt.Sprintf("%d %02d %03d", d.F, d.X, d.Y)
}

func (d Descriptor) IsLocal() bool {
	return (d.F == 0 || d.F == 3) && (d.X >= 48 || d.Y >= 192)
}

type Value struct {
	Descriptor Descriptor
	Name       string
	Unit       string
	Float      *float64
	String     *string
	Value      any
}

func (v Value) IsMissing() bool {
	return v.Float == nil && v.String == nil
}

type Message struct {
	Edition            int
	MasterTable        int
	MasterTableVersion int
	LocalTableVersion  int
	Centre             int
	SubCentre          int
	DataCategory       int
	DataSubcategory    int
	Compressed         bool
	Subsets            [][]Value
}

type ErrLocalDescriptor struct {
	Descriptor Descriptor
}

func (e ErrLocalDescriptor) Error() string {
	return fmt.Sprintf("local descriptor not supported: %s (%06d)", e.Descriptor, e.Descriptor.Code())
}

type ErrUnknownDescriptor struct {
	Descriptor Descriptor
}

func (e ErrUnknownDescriptor) Error() string {
	return fmt.Sprintf("unknown descriptor: %s (%06d)", e.Descriptor, e.Descriptor.Code())
}

type ErrTruncated struct {
	Detail string
}

func (e ErrTruncated) Error() string {
	return fmt.Sprintf("truncated BUFR data: %s", e.Detail)
}

type ErrInvalidBUFR struct {
	Detail string
}

func (e ErrInvalidBUFR) Error() string {
	return fmt.Sprintf("invalid BUFR: %s", e.Detail)
}

type ErrLimitExceeded struct {
	Detail string
}

func (e ErrLimitExceeded) Error() string {
	return fmt.Sprintf("limit exceeded: %s", e.Detail)
}

type ErrNoBUFRFound struct {
	Detail string
}

func (e ErrNoBUFRFound) Error() string {
	return fmt.Sprintf("no BUFR message found: %s", e.Detail)
}
