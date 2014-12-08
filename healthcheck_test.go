package main_test

import (
	"net/http"
	"net/http/httptest"

	. "github.com/alphagov/publishing-api"

	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"
)

var _ = Describe("Healthcheck", func() {
	It("responds with a status of OK", func() {
		httpMux := BuildHTTPMux()
		testServer := httptest.NewServer(httpMux)
		defer testServer.Close()

		response, err := http.Get(testServer.URL + "/healthcheck")
		Expect(err).To(BeNil())
		Expect(response.StatusCode).To(Equal(http.StatusOK))

		body, err := readResponseBody(response)
		Expect(err).To(BeNil())
		Expect(body).To(Equal(`{"status":"OK"}`))
	})
})
