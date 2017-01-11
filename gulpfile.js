"use strict";

const gulp = require("gulp"),
    sass = require("gulp-sass"),
    imagemin = require("gulp-imagemin");

gulp.task("sass", function () {
    return gulp.src("./resources/sass/main.scss")
        .pipe(sass({
            outputStyle: "compressed",
            includePaths: [
                "./node_modules"
            ]
        }).on("error", sass.logError))
        .pipe(gulp.dest("./public/css"));
});

gulp.task("images", function () {
    return gulp.src("./resources/img/**/*")
        .pipe(imagemin())
        .pipe(gulp.dest("./public/img"));
})

gulp.task("watch", ["default"], function () {
    gulp.watch("./resources/sass/**/*.scss", ["sass"]);
    gulp.watch("./resources/img/**/*", ["images"]);
});

gulp.task("default", ["sass", "images"]);