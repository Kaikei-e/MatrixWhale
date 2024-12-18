package main

import (
	"fmt"
	"net/http"

	"github.com/labstack/echo/v4"
)

func main() {
	fmt.Println("Hello, World!")

	e := echo.New()
	e.GET("/api/v1/health", func(c echo.Context) error {
		return c.String(http.StatusOK, "OK")
	})

	e.Start(":8085")
}
