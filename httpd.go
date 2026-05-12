package main

import (
	"log"
	"net/http"
)

func main() {
	log.Println("listening on http://0.0.0.0:8080/")
	if err := http.ListenAndServe(":8080", http.FileServer(http.Dir("."))); err != nil {
		log.Fatal(err)
	}
}
