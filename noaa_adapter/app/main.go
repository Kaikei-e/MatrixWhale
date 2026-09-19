package main

import (
	"fmt"
	"matrixwhale/adapters/common/metrics"
	"noaa_adapter/controller"
	"noaa_adapter/initialize"
)

func main() {
	initialize.InitLogger()
	metrics.Serve()

	controller.ManageRESTRequest()

	fmt.Println("Process finished")
}
