package adapter

import (
	"context"
	"net/url"
	"strings"
	"sync"
	"time"
)

// HostLimiter enforces politeness rules:
// 1. One in-flight request per host.
// 2. At least minHostInterval between the end of one request and the start of the next to the same host.
// 3. At most maxParallelHosts distinct hosts in flight concurrently.
type HostLimiter struct {
	minHostInterval  time.Duration
	maxParallelHosts int
	globalSem        chan struct{}

	mu    sync.Mutex
	hosts map[string]*hostState

	now   func() time.Time
	sleep func(context.Context, time.Duration) error
}

type hostState struct {
	sem     chan struct{}
	mu      sync.Mutex
	lastEnd time.Time
	hasRun  bool
}

func NewHostLimiter(minHostInterval time.Duration, maxParallelHosts int) *HostLimiter {
	if maxParallelHosts <= 0 {
		maxParallelHosts = 1
	}
	return newHostLimiterWithClock(minHostInterval, maxParallelHosts, time.Now, sleepWithContext)
}

func newHostLimiterWithClock(
	minHostInterval time.Duration,
	maxParallelHosts int,
	now func() time.Time,
	sleep func(context.Context, time.Duration) error,
) *HostLimiter {
	if maxParallelHosts <= 0 {
		maxParallelHosts = 1
	}
	return &HostLimiter{
		minHostInterval:  minHostInterval,
		maxParallelHosts: maxParallelHosts,
		globalSem:        make(chan struct{}, maxParallelHosts),
		hosts:            make(map[string]*hostState),
		now:              now,
		sleep:            sleep,
	}
}

func (hl *HostLimiter) getHostState(host string) *hostState {
	hl.mu.Lock()
	defer hl.mu.Unlock()

	hs, ok := hl.hosts[host]
	if !ok {
		hs = &hostState{
			sem: make(chan struct{}, 1),
		}
		hl.hosts[host] = hs
	}
	return hs
}

// Wait blocks until the caller is allowed to make a request to the given host.
// On success, the caller MUST call Done(host) when the request completes.
func (hl *HostLimiter) Wait(ctx context.Context, host string) error {
	hs := hl.getHostState(host)

	// Acquire exclusive access to this host.
	select {
	case hs.sem <- struct{}{}:
	case <-ctx.Done():
		return ctx.Err()
	}

	// Check if we need to sleep to respect minHostInterval.
	hs.mu.Lock()
	var waitDuration time.Duration
	if hs.hasRun {
		elapsed := hl.now().Sub(hs.lastEnd)
		if elapsed < hl.minHostInterval {
			waitDuration = hl.minHostInterval - elapsed
		}
	}
	hs.mu.Unlock()

	if waitDuration > 0 {
		if err := hl.sleep(ctx, waitDuration); err != nil {
			<-hs.sem
			return err
		}
	}

	// Acquire a global in-flight slot across all hosts.
	select {
	case hl.globalSem <- struct{}{}:
	case <-ctx.Done():
		<-hs.sem
		return ctx.Err()
	}

	return nil
}

// Done records the completion of a request to host and releases concurrency slots.
func (hl *HostLimiter) Done(host string) {
	hs := hl.getHostState(host)

	// Release global slot first so another host can proceed.
	select {
	case <-hl.globalSem:
	default:
	}

	hs.mu.Lock()
	hs.lastEnd = hl.now()
	hs.hasRun = true
	hs.mu.Unlock()

	// Release host exclusivity.
	select {
	case <-hs.sem:
	default:
	}
}

// HostFromURL extracts the host (lowercased) from a URL string.
func HostFromURL(rawURL string) string {
	u, err := url.Parse(rawURL)
	if err != nil {
		return strings.ToLower(rawURL)
	}
	hostname := strings.ToLower(u.Hostname())
	if hostname == "" {
		return strings.ToLower(rawURL)
	}
	return hostname
}

func sleepWithContext(ctx context.Context, d time.Duration) error {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
