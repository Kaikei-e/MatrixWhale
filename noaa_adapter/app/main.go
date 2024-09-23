package main

import (
	"fmt"
	"noaa_adapter/controller"
	"noaa_adapter/initialize"
)

func main() {
	initialize.InitLogger()

	controller.ManageRESTRequest()

	fmt.Println("Process finished")
}
