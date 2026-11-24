// Emscripten JS library for the web player (linked by ExportPipeline via --js-library).
addToLibrary({
    // Suspends the Wasm stack through JSPI until the browser is ready for the next frame.
    // Returning to the event loop is also what presents the WebGPU canvas.
    engine_web_next_frame__async: true,
    engine_web_next_frame__deps: ['$Asyncify'],
    engine_web_next_frame: function () {
        return Asyncify.handleAsync(function () {
            return new Promise(function (resolve) {
                requestAnimationFrame(function () { resolve(); });
            });
        });
    }
});
