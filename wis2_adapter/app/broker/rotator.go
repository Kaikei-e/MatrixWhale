package broker

import (
	"math/rand"
	"sync"
	"time"

	"matrixwhale/adapters/common/poll"
)

type Rotator struct {
	mu           sync.Mutex
	brokers      []string
	currentIndex int
	backoff      time.Duration
	floor        time.Duration
	ceiling      time.Duration
	maxJitter    time.Duration
	rng          *rand.Rand
}

func NewRotator(brokers []string, floor, ceiling, maxJitter time.Duration) *Rotator {
	if len(brokers) == 0 {
		brokers = []string{"mqtts://localhost:8883"}
	}
	if floor <= 0 {
		floor = 1 * time.Second
	}
	if ceiling <= 0 {
		ceiling = 30 * time.Second
	}
	return &Rotator{
		brokers:   brokers,
		floor:     floor,
		ceiling:   ceiling,
		maxJitter: maxJitter,
		rng:       rand.New(rand.NewSource(time.Now().UnixNano())),
	}
}

func (r *Rotator) Current() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.brokers[r.currentIndex]
}

func (r *Rotator) Rotate() (string, time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.currentIndex = (r.currentIndex + 1) % len(r.brokers)
	r.backoff = poll.ComputeBackoff(nil, r.backoff, r.floor, r.ceiling)
	delay := poll.Jitter(r.backoff, r.maxJitter, r.rng)
	return r.brokers[r.currentIndex], delay
}

func (r *Rotator) ResetBackoff() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.backoff = 0
}

func (r *Rotator) CurrentIndex() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.currentIndex
}
