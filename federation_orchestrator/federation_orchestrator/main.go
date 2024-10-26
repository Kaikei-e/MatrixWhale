package main

import (
	"federation_orchestrator/initialize"
	"fmt"
	"net/http"
)

func main() {
	initialize.InitLogger()

	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	server := &http.Server{
		Addr:    ":5000",
		Handler: mux,
	}

	if err := server.ListenAndServe(); err != nil {
		fmt.Println("Error starting server:", err)
	}
}
