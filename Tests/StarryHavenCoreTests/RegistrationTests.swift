import Foundation
import Testing
@testable import StarryHavenCore

@Suite("Star detection and Siril-style registration")
struct RegistrationTests {
    @Test func starDetectionFindsSyntheticStars() throws {
        let stars = SyntheticScene.randomStars(width: 512, height: 512, count: 40, seed: 11)
        let image = SyntheticScene.starField(width: 512, height: 512, stars: stars, noise: 0.002, seed: 3)
        let field = StarDetector.detect(image: image)
        print("detected \(field.stars.count) stars, background \(field.background), noise \(field.noise)")
        #expect(field.stars.count >= 36)
        #expect(field.stars.count <= 44)
        #expect(field.noise > 0.0005)
        let fwhm = field.stars.map { $0.fwhm }.sorted()
        let medianFWHM = fwhm[fwhm.count / 2]
        print("median FWHM \(medianFWHM) (input sigma 1.2...2.4)")
        #expect(medianFWHM > 2.6)
        #expect(medianFWHM < 6.5)
    }

    @Test func sirilStyleRegistrationRecoversKnownTransform() throws {
        let width = 1024, height = 1024
        let refStars = SyntheticScene.randomStars(width: width, height: height, count: 80, seed: 42,
                                                  minSeparation: 18, sigmaRange: 1.4...2.0)
        let reference = SyntheticScene.starField(width: width, height: height, stars: refStars,
                                                 background: 0.015, backgroundGradient: 0.006,
                                                 noise: 0.003, seed: 100)
        // Ground truth maps reference coordinates to image coordinates.
        let truth = makeSimilarity(scale: 1.01, rotationDegrees: 1.2, tx: 17.0, ty: -9.0)
        var image = try #require(Warp.warp(reference, imageToReference: truth, outputWidth: width, outputHeight: height)).image
        let spurious = SyntheticScene.randomStars(width: width, height: height, count: 20, seed: 999,
                                                  minSeparation: 18, peakRange: 0.05...0.6)
        for s in spurious { SyntheticScene.addStar(to: &image, s) }
        var rng = SyntheticScene.Random(seed: 55)
        for i in 0..<image.pixels.count {
            image.pixels[i] = max(0, image.pixels[i] + Float(rng.gaussian() * 0.003))
        }

        let refField = StarDetector.detect(image: reference)
        let imgField = StarDetector.detect(image: image)
        print("reference stars \(refField.stars.count), image stars \(imgField.stars.count)")
        #expect(refField.stars.count > 60)
        #expect(imgField.stars.count > 75)

        let result = try StarRegistration.register(reference: refField, image: imgField,
                                                   referenceWidth: width, referenceHeight: height,
                                                   imageWidth: width, imageHeight: height)
        print("registration: \(result.message)")
        TestEvidence.write("""
        detected image stars: \(imgField.stars.count)
        detected reference stars: \(refField.stars.count)
        reference triangles: \(result.referenceTriangles)
        image triangles: \(result.imageTriangles)
        candidate triangles: \(result.candidateTriangles)
        vote peak: \(result.votes)
        model: \(result.modelType.rawValue)
        matches: \(result.matches)
        inliers: \(result.inliers)
        rms: \(result.rms)
        """, name: "registration.log")

        #expect(result.rms < 0.5)
        #expect(result.inliers > 40)
        #expect(result.votes > 3)

        // Parameter checks against the known ground truth: recovered transform is truth^-1.
        let expected = try #require(truth.inverse)
        let probe = (x: 512.0, y: 512.0)
        let pGot = result.transform.apply(probe.x, probe.y)
        let pExp = expected.apply(probe.x, probe.y)
        let centerError = hypot(pGot.x - pExp.x, pGot.y - pExp.y)
        let rotationError = abs(result.transform.rotationRadians - expected.rotationRadians) * 180 / .pi
        let scaleError = abs(result.transform.affineScale / expected.affineScale - 1)
        print(String(format: "center error %.4f px, rotation error %.4f deg, scale error %.5f", centerError, rotationError, scaleError))
        #expect(centerError < 1.0)
        #expect(rotationError < 0.2)
        #expect(scaleError < 0.01)

        // Warp with the recovered transform and measure star alignment in the reference frame.
        let warped = try #require(Warp.warp(image, imageToReference: result.transform, outputWidth: width, outputHeight: height))
        let warpedField = StarDetector.detect(image: warped.image)
        let alignment = alignedStarRMS(reference: refField, warped: warpedField)
        print(String(format: "warped star alignment RMS %.4f px over %d stars", alignment.rms, alignment.matched))
        TestEvidence.write(String(format: "warped alignment rms: %.4f px matched: %d", alignment.rms, alignment.matched), name: "registration-warp-rms.log")
        #expect(alignment.matched > 40)
        #expect(alignment.rms < 0.5)
        TestEvidence.save(warped.image, name: "registration-warped.png")
        TestEvidence.save(reference, name: "registration-reference.png")
    }

    @Test func registrationRejectsUnrelatedStarFields() throws {
        let starsA = SyntheticScene.randomStars(width: 512, height: 512, count: 80, seed: 301, minSeparation: 12)
        let starsB = SyntheticScene.randomStars(width: 512, height: 512, count: 80, seed: 302, minSeparation: 12)
        let imageA = SyntheticScene.starField(width: 512, height: 512, stars: starsA, noise: 0.001, seed: 1)
        let imageB = SyntheticScene.starField(width: 512, height: 512, stars: starsB, noise: 0.001, seed: 2)
        let fieldA = StarDetector.detect(image: imageA)
        let fieldB = StarDetector.detect(image: imageB)
        do {
            _ = try StarRegistration.register(reference: fieldA, image: fieldB,
                                              referenceWidth: 512, referenceHeight: 512,
                                              imageWidth: 512, imageHeight: 512)
            Issue.record("unrelated star fields should be rejected instead of warped")
        } catch let error as RegistrationError {
            TestEvidence.write("unrelated fields rejected: \(error)", name: "registration-unrelated.log")
        }
    }

    @Test func registrationRejectsThreeStarField() throws {
        let stars = SyntheticScene.randomStars(width: 512, height: 512, count: 3, seed: 8, minSeparation: 10)
        let image = SyntheticScene.starField(width: 512, height: 512, stars: stars, noise: 0.001, seed: 4)
        let field = StarDetector.detect(image: image)
        #expect(field.stars.count <= 3)
        do {
            _ = try StarRegistration.register(reference: field, image: field,
                                              referenceWidth: 512, referenceHeight: 512,
                                              imageWidth: 512, imageHeight: 512)
            Issue.record("three-star field should not register")
        } catch let error as RegistrationError {
            guard case .insufficientStars = error else {
                Issue.record("expected insufficientStars, got \(error)")
                return
            }
            TestEvidence.write("three-star field rejected: \(error)", name: "registration-reject.log")
        }
    }
}
