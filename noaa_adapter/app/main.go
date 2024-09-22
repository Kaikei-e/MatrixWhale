package main

import (
	"fmt"
	"noaa_adapter/adapter"
	"noaa_adapter/initialize"
	"sync"
	"time"
)

func main() {
	initialize.InitLogger()

	wg := sync.WaitGroup{}
	wg.Add(1)

	go func() {
		defer wg.Done()
		for {
			adapter.NoaaAlertsAdapter()
			time.Sleep(30 * time.Second)
		}
	}()

	wg.Wait()
	fmt.Println("Hello, World!")
}
