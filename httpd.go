package main

import (
	"log"
	"net/http"
	"os"
)

func main() {
	body, err := os.ReadFile("public/bench.txt")
	if err != nil {
		log.Fatal(err)
	}
	http.HandleFunc("/bench", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Connection", "close")
		w.Write(body)
	})
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Fatal(http.ListenAndServe(os.Getenv("HOST")+":"+port, nil))
}
