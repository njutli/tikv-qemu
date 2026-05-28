package main

import (
	"context"
	"crypto/rand"
	"fmt"
	"time"

	"github.com/pingcap/errors"
	"github.com/tikv/client-go/v2/config"
	"github.com/tikv/client-go/v2/rawkv"
)

func main() {
	pdAddrs := []string{"172.16.0.101:2379"}

	// Initialize TiKV RawKV client
	client, err := rawkv.NewClient(context.Background(), pdAddrs, config.DefaultConfig().Security)
	if err != nil {
		panic(errors.Trace(err))
	}
	defer client.Close()

	fmt.Println("========================================")
	fmt.Println("TiKV RawKV Read/Write Test")
	fmt.Println("Simulating JuiceFS metadata patterns")
	fmt.Println("========================================")
	fmt.Printf("PD: %v\n\n", pdAddrs)

	// ============================================================
	// Test 1: Basic Put + Get (simulate file creation + stat)
	// ============================================================
	fmt.Println("[Test 1] Basic Put/Get (single key)")
	key1 := []byte("juicefs:test:file:inode:1001")
	value1 := make([]byte, 256)
	rand.Read(value1)

	start := time.Now()
	err = client.Put(context.Background(), key1, value1)
	if err != nil {
		panic(err)
	}
	fmt.Printf("  Put   %s (%d bytes) ... %v\n", key1, len(value1), time.Since(start))

	start = time.Now()
	got, err := client.Get(context.Background(), key1)
	if err != nil {
		panic(err)
	}
	fmt.Printf("  Get   %s (%d bytes) ... %v\n", key1, len(got), time.Since(start))

	if string(got) != string(value1) {
		panic("value mismatch!")
	}
	fmt.Println("  Result: PASS\n")

	// ============================================================
	// Test 2: Batch Put (simulate bulk file creation)
	// ============================================================
	fmt.Println("[Test 2] Batch Put (100 keys, simulating metadata ops)")
	batchKeys := make([][]byte, 0, 100)
	batchValues := make([][]byte, 0, 100)

	for i := 0; i < 100; i++ {
		k := []byte(fmt.Sprintf("juicefs:test:file:inode:%04d", 2000+i))
		v := make([]byte, 128)
		rand.Read(v)
		batchKeys = append(batchKeys, k)
		batchValues = append(batchValues, v)
	}

	start = time.Now()
	err = client.BatchPut(context.Background(), batchKeys, batchValues)
	if err != nil {
		panic(err)
	}
	fmt.Printf("  BatchPut 100 keys (128B each) ... %v\n", time.Since(start))

	// Batch Get (simulate directory listing / metadata scan)
	start = time.Now()
	matchCount := 0
	for i := 0; i < 100; i++ {
		v, err := client.Get(context.Background(), batchKeys[i])
		if err != nil {
			panic(err)
		}
		if string(v) == string(batchValues[i]) {
			matchCount++
		}
	}
	fmt.Printf("  BatchGet 100 keys ... %v (matched: %d/100)\n", time.Since(start), matchCount)
	if matchCount != 100 {
		panic(fmt.Sprintf("batch validation failed: %d/100", matchCount))
	}
	fmt.Println("  Result: PASS\n")

	// ============================================================
	// Test 3: Scan (simulate directory traversal)
	// ============================================================
	fmt.Println("[Test 3] Scan range (simulating directory listing)")
	start = time.Now()
	scanKeys, _, err := client.Scan(
		context.Background(),
		[]byte("juicefs:test:file:inode:2000"),
		[]byte("juicefs:test:file:inode:2100"),
		200,
	)
	if err != nil {
		panic(err)
	}
	fmt.Printf("  Scan returned %d keys ... %v\n", len(scanKeys), time.Since(start))
	if len(scanKeys) != 100 {
		panic(fmt.Sprintf("scan expected 100 keys, got %d", len(scanKeys)))
	}
	fmt.Println("  Result: PASS\n")

	// ============================================================
	// Test 4: Delete (simulate file deletion)
	// ============================================================
	fmt.Println("[Test 4] Delete (simulating file removal)")
	start = time.Now()
	err = client.Delete(context.Background(), key1)
	if err != nil {
		panic(err)
	}
	fmt.Printf("  Delete %s ... %v\n", key1, time.Since(start))

	gotAfter, err := client.Get(context.Background(), key1)
	if err != nil {
		panic(err)
	}
	if gotAfter != nil {
		panic("key should be deleted but still exists")
	}
	fmt.Printf("  Get after delete: nil (key not found)\n")
	fmt.Println("  Result: PASS\n")

	// ============================================================
	// Test 5: Concurrent puts (simulate multi-client workload)
	// ============================================================
	fmt.Println("[Test 5] Concurrent Puts (10 goroutines × 50 keys each)")
	concurrency := 10
	keysPerRoutine := 50
	errCh := make(chan error, concurrency)

	start = time.Now()
	for r := 0; r < concurrency; r++ {
		go func(routineID int) {
			for i := 0; i < keysPerRoutine; i++ {
				k := []byte(fmt.Sprintf("juicefs:test:concurrent:%02d:%04d", routineID, 3000+i))
				v := []byte(fmt.Sprintf("value-from-routine-%d-key-%d", routineID, i))
				if err := client.Put(context.Background(), k, v); err != nil {
					errCh <- err
					return
				}
			}
			errCh <- nil
		}(r)
	}

	errCount := 0
	for i := 0; i < concurrency; i++ {
		if err := <-errCh; err != nil {
			errCount++
			fmt.Printf("  routine %d failed: %v\n", i, err)
		}
	}
	fmt.Printf("  %d concurrent × %d keys ... %v\n", concurrency, keysPerRoutine, time.Since(start))
	if errCount > 0 {
		panic(fmt.Sprintf("%d routines failed", errCount))
	}
	fmt.Println("  Result: PASS\n")

	// ============================================================
	// Summary
	// ============================================================
	fmt.Println("========================================")
	fmt.Println("All 5 tests PASSED")
	fmt.Println("========================================")
	fmt.Println("Test patterns suitable for JuiceFS metadata:")
	fmt.Println("  - Small key/value pairs (128-256B)")
	fmt.Println("  - Batch operations (directory ops)")
	fmt.Println("  - Range scans (directory listing)")
	fmt.Println("  - Concurrent access (multi-client)")
	fmt.Println("  - Deletes (file removal)")
}
