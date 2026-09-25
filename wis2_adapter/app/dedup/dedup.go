package dedup

import (
	"sync"
	"time"
)

type Cache struct {
	mu              sync.Mutex
	notificationTTL time.Duration
	dataIDTTL       time.Duration
	notifications   map[string]time.Time
	dataIDs         map[string]time.Time
	now             func() time.Time
}

func New() *Cache {
	return NewWithTTL(1*time.Hour, 24*time.Hour, time.Now)
}

func NewWithTTL(notificationTTL, dataIDTTL time.Duration, now func() time.Time) *Cache {
	if now == nil {
		now = time.Now
	}
	return &Cache{
		notificationTTL: notificationTTL,
		dataIDTTL:       dataIDTTL,
		notifications:   make(map[string]time.Time),
		dataIDs:         make(map[string]time.Time),
		now:             now,
	}
}

func (c *Cache) CheckOrAdd(notificationID, dataID string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()

	currentTime := c.now()

	c.cleanup(currentTime)

	isDuplicate := false
	if notificationID != "" {
		if exp, ok := c.notifications[notificationID]; ok && currentTime.Before(exp) {
			isDuplicate = true
		}
	}
	if dataID != "" {
		if exp, ok := c.dataIDs[dataID]; ok && currentTime.Before(exp) {
			isDuplicate = true
		}
	}

	if isDuplicate {
		return true
	}

	if notificationID != "" {
		c.notifications[notificationID] = currentTime.Add(c.notificationTTL)
	}
	if dataID != "" {
		c.dataIDs[dataID] = currentTime.Add(c.dataIDTTL)
	}
	return false
}

func (c *Cache) cleanup(now time.Time) {
	if len(c.notifications) > 500 {
		for k, exp := range c.notifications {
			if !now.Before(exp) {
				delete(c.notifications, k)
			}
		}
	}
	if len(c.dataIDs) > 500 {
		for k, exp := range c.dataIDs {
			if !now.Before(exp) {
				delete(c.dataIDs, k)
			}
		}
	}
}
