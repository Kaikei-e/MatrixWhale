package adapter

import (
	"context"
	"time"
)

// Batcher groups live messages into batches of Size, flushing early once
// MaxWait has elapsed since the first message of the current batch.
type Batcher struct {
	Size    int
	MaxWait time.Duration
}

// Run reads from in until it closes or ctx is done, sending completed
// batches to out. It always closes out before returning, flushing any
// partially filled batch first so a disconnect never drops buffered
// messages.
func (b Batcher) Run(ctx context.Context, in <-chan LiveMessage, out chan<- []LiveMessage) {
	defer close(out)

	var buf []LiveMessage
	var timer *time.Timer
	var timerC <-chan time.Time

	flush := func() {
		if len(buf) == 0 {
			return
		}
		batch := buf
		buf = nil
		select {
		case out <- batch:
		case <-ctx.Done():
		}
		if timer != nil {
			timer.Stop()
			timer = nil
			timerC = nil
		}
	}

	for {
		select {
		case msg, ok := <-in:
			if !ok {
				flush()
				return
			}
			buf = append(buf, msg)
			if timer == nil {
				timer = time.NewTimer(b.MaxWait)
				timerC = timer.C
			}
			if len(buf) >= b.Size {
				flush()
			}
		case <-timerC:
			flush()
		case <-ctx.Done():
			flush()
			return
		}
	}
}
