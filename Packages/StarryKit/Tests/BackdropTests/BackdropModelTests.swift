import simd
import Testing
@testable import Backdrop

@Suite struct BackdropModelTests {
    @Test func viewMatrixMakesArtworkSquareOnTheLongerSide() {
        // Landscape 16:9: one clip unit must map to the same pixel length on both axes.
        let aspect: Float = 16.0 / 9.0
        let m = BackdropLook.viewMatrix(aspect: aspect)
        let px = SIMD2(m.columns.0.x * 1600 / 2, m.columns.1.y * 900 / 2)
        #expect(abs(px.x - px.y) < 1e-3)
        let portrait = BackdropLook.viewMatrix(aspect: 0.5)
        let py = SIMD2(portrait.columns.0.x * 500 / 2, portrait.columns.1.y * 1000 / 2)
        #expect(abs(py.x - py.y) < 1e-3)
    }

    @Test func instancesRotateWithTheirPeriods() {
        let a = BackdropLook.instanceMatrix(index: 0, time: 0, aspect: 1, power: .zero)
        let b = BackdropLook.instanceMatrix(index: 0, time: 120, aspect: 1, power: .zero)
        #expect(simd_almost_equal_elements(a, b, 1e-3))
        let quarter = BackdropLook.instanceMatrix(index: 0, time: 30, aspect: 1, power: .zero)
        let p = quarter * SIMD4<Float>(1, 0, 0, 1)
        #expect(abs(abs(p.y) - 1.4) < 1e-3 && abs(p.x) < 1e-3)
        let third = BackdropLook.instanceMatrix(index: 2, time: 0, aspect: 1, power: .zero)
        let center = third * SIMD4<Float>(0, 0, 0, 1)
        #expect(abs(center.x - 0.7) < 1e-4 && abs(center.y - 0.7) < 1e-4)
        let corner = third * SIMD4<Float>(1, 0, 0, 1)
        #expect(abs(corner.x - 1.4) < 1e-4)
    }

    @Test func spectrumScaleAndPower() {
        #expect(BackdropLook.spectrumScale(power: .zero) == 1)
        #expect(abs(BackdropLook.spectrumScale(power: SIMD4(1, 1, 0, 0)) - 1.33) < 1e-5)
        var s = SpectrumPower()
        s.update(input: SIMD4(1, 1, 1, 1), dt: 1 / 60)
        #expect(abs(s.smoothed.x - 0.5) < 1e-5)
        for _ in 0..<600 { s.update(input: .zero, dt: 1 / 60) }
        #expect(s.smoothed.w < 1e-3)
        #expect(s.smoothed.x < 0.01)
        #expect(s.smoothed.z > 0.5)
        let calm = s.power(intensity: 0.2)
        let lively = s.power(intensity: 1)
        #expect(calm.z < lively.z)
        #expect(lively.z <= 1 && lively.z >= 0)
    }

    @Test func timingCurves() {
        #expect(CubicBezier.easeOut.solve(0) == 0)
        #expect(CubicBezier.easeOut.solve(1) == 1)
        #expect(CubicBezier.easeOut.solve(0.3) > 0.55)
        #expect(abs(CubicBezier.easeInOut.solve(0.5) - 0.5) < 1e-3)
        #expect(CubicBezier.easeInOut.solve(0.1) < 0.1)
    }

    @Test func subdivisionMatchesReferenceValues() {
        func grid(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] { PinchMesh.subdivide(points, cells: 2) }
        func at(_ q: [SIMD2<Float>], _ i: Int, _ j: Int) -> SIMD2<Float> { q[j * 5 + i] }
        let interior = grid([SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(1, 0), SIMD2(0, 0.5), SIMD2(0.7, 0.6), SIMD2(1, 0.5), SIMD2(0, 1), SIMD2(0.5, 1), SIMD2(1, 1)])
        #expect(simd_distance(at(interior, 2, 2), SIMD2(0.6125, 0.55625)) < 1e-5)
        #expect(simd_distance(at(interior, 1, 1), SIMD2(0.3, 0.275)) < 1e-5)
        #expect(simd_distance(at(interior, 2, 1), SIMD2(0.575, 0.2875)) < 1e-5)
        let border = grid([SIMD2(0.1, 0.05), SIMD2(0.6, -0.2), SIMD2(1, 0), SIMD2(0, 0.5), SIMD2(0.5, 0.5), SIMD2(1.1, 0.4), SIMD2(0, 1), SIMD2(0.5, 1), SIMD2(1, 1)])
        #expect(at(border, 0, 0) == SIMD2(0.1, 0.05))
        #expect(simd_distance(at(border, 2, 0), SIMD2(0.5875, -0.14375)) < 1e-5)
        #expect(simd_distance(at(border, 1, 0), SIMD2(0.35, -0.075)) < 1e-5)
        #expect(simd_distance(at(border, 4, 2), SIMD2(1.075, 0.425)) < 1e-5)
    }

    @Test func pinchMeshesMatchSubdividedGrids() {
        let landscape = PinchMesh.make(landscape: true, seed: 2)
        #expect(landscape.vertices.count == 33 * 33)
        #expect(landscape.indices.count == 32 * 32 * 6)
        func to(_ mesh: [PinchMesh.Vertex], _ u: Float, _ v: Float) -> SIMD2<Float>? {
            mesh.first { simd_distance($0.uv, SIMD2(u, v)) < 1e-5 }?.to
        }
        #expect(simd_distance(to(landscape.vertices, 0.5, 0.5)!, SIMD2(-0.023474, -0.300733)) < 1e-4)
        #expect(simd_distance(to(landscape.vertices, 0.25, 0.75)!, SIMD2(-0.552883, 0.512746)) < 1e-4)
        #expect(simd_distance(to(landscape.vertices, 0, 0.5)!, SIMD2(-1.236456, 0.161194)) < 1e-4)
        #expect(simd_distance(to(landscape.vertices, 0.125, 0)!, SIMD2(-0.819088, -1.282269)) < 1e-4)
        let portrait = PinchMesh.make(landscape: false, seed: 0)
        #expect(portrait.vertices.count == 21 * 21)
        #expect(simd_distance(to(portrait.vertices, 0.5, 0.5)!, SIMD2(-0.022798, 0.134806)) < 1e-4)
        #expect(simd_distance(to(portrait.vertices, 0.2, 0.35)!, SIMD2(-0.523436, -0.007818)) < 1e-4)
        #expect(simd_distance(to(portrait.vertices, 1, 0.4)!, SIMD2(1, -0.2)) < 1e-4)
        let flat = PinchMesh.make(landscape: true, seed: 2, strength: 0)
        #expect(flat.vertices.allSatisfy { simd_distance($0.to, $0.uv * 2 - 1) < 1e-5 })
        #expect(PinchMesh.make(landscape: true, seed: 2, strength: 2) == landscape)
    }

    @Test func gradeTamesRedAndBlueOnly() {
        let red = BackdropGrade.apply(SIMD3(1, 0, 0))
        #expect(red.x < 0.75 && red.y > 0.03)
        let blue = BackdropGrade.apply(SIMD3(0, 0, 1))
        #expect(blue.z < 0.75)
        let green = BackdropGrade.apply(SIMD3(0, 1, 0))
        #expect(green == SIMD3(0, 1, 0))
        let grey = BackdropGrade.apply(SIMD3(0.4, 0.4, 0.4))
        #expect(grey == SIMD3(0.4, 0.4, 0.4))
        let magenta = BackdropGrade.apply(SIMD3(0.97, 0, 0.71))
        #expect(magenta.x > 0.9)
        let orange = BackdropGrade.apply(SIMD3(0.97, 0.48, 0.13))
        #expect(orange.x < 0.85)
        let hue = { (c: SIMD3<Float>) in (c.y - c.z) / (c.x - c.z) }
        #expect(abs(hue(orange) - hue(SIMD3(0.97, 0.48, 0.13))) < 0.01)
    }
}
