package main

import (
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"sync"
	"time"
)

func main() {
	url := flag.String("url", "", "target URL")
	n := flag.Int("n", 10000, "total requests")
	c := flag.Int("c", 1, "concurrency")
	keepalive := flag.Bool("keepalive", false, "use HTTP keep-alive (default: fresh TCP each)")
	flag.Parse()
	if *url == "" {
		fmt.Fprintln(os.Stderr, "usage: bench -url <url> [-n N] [-c C] [-keepalive]")
		os.Exit(2)
	}

	tr := &http.Transport{
		DisableKeepAlives:   !*keepalive,
		MaxIdleConnsPerHost: *c,
	}
	client := &http.Client{Transport: tr, Timeout: 10 * time.Second}

	var wg sync.WaitGroup
	jobs := make(chan int, *n)
	for i := 0; i < *n; i++ {
		jobs <- i
	}
	close(jobs)

	var mu sync.Mutex
	lats := make([]time.Duration, 0, *n)
	var fails int

	start := time.Now()
	for w := 0; w < *c; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range jobs {
				t0 := time.Now()
				resp, err := client.Get(*url)
				if err != nil {
					mu.Lock()
					fails++
					mu.Unlock()
					continue
				}
				io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
				dt := time.Since(t0)
				mu.Lock()
				lats = append(lats, dt)
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	total := time.Since(start)

	sort.Slice(lats, func(i, j int) bool { return lats[i] < lats[j] })
	pct := func(p float64) time.Duration {
		if len(lats) == 0 {
			return 0
		}
		i := int(float64(len(lats)-1) * p)
		return lats[i]
	}
	rps := float64(len(lats)) / total.Seconds()
	fmt.Printf("requests : %d ok / %d fail in %v\n", len(lats), fails, total.Round(time.Millisecond))
	fmt.Printf("rps      : %.0f\n", rps)
	fmt.Printf("latency  : p50=%v p90=%v p99=%v max=%v\n",
		pct(0.50).Round(time.Microsecond),
		pct(0.90).Round(time.Microsecond),
		pct(0.99).Round(time.Microsecond),
		lats[len(lats)-1].Round(time.Microsecond),
	)
}
