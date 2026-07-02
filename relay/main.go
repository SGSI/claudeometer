// Command claudeometer-relay is the self-hosted relay for Claudeometer Teams.
//
// It serves the M2 wire protocol (relay/PROTOCOL.md): enrollment, a usage
// board, and Ed25519-signed requests, backed by SQLite.
package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"claudeometer-relay/server"
	"claudeometer-relay/store"
)

// version is stamped at build time via -ldflags "-X main.version=..."; defaults
// to "dev" for local builds.
var version = "dev"

func main() {
	port := getenv("PORT", "8080")
	dbPath := getenv("DB_PATH", "./relay.db")

	st, err := store.Open(dbPath)
	if err != nil {
		log.Fatalf("open store %q: %v", dbPath, err)
	}
	defer st.Close()

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           logRequests(server.New(st, version).Handler()),
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		log.Printf("claudeometer-relay %s listening on :%s (db=%s)", version, port, dbPath)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("server error: %v", err)
		}
	}()

	// Graceful shutdown on SIGINT/SIGTERM (systemd sends SIGTERM on stop).
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	log.Println("shutting down...")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		log.Printf("shutdown error: %v", err)
	}
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %s", r.Method, r.URL.Path, time.Since(start))
	})
}
