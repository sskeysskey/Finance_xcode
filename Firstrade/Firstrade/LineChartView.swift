import SwiftUI

struct LineChartView: View {
    let dataPoints: [DealDataPoint]
    let strokeColor: Color
    let axisColor: Color
    let axisLabelColor: Color

    private var maxY: Double { (dataPoints.map { $0.value }.max() ?? 0) }
    private var minY: Double { (dataPoints.map { $0.value }.min() ?? 0) }
    private var ySpread: Double {
        let spread = maxY - minY
        return spread == 0 ? 1 : spread // 0除算を避ける
    }

    var body: some View {
        GeometryReader { geometry in
            if dataPoints.isEmpty {
                Text("图表无可用数据")
                    .foregroundColor(axisLabelColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                Path { path in
                    // グラフの描画領域を少し内側にオフセットする（ラベルのため）
                    let drawingWidth = geometry.size.width * 0.9 // 左右に5%ずつのマージン
                    let drawingHeight = geometry.size.height * 0.9 // 上下に5%ずつのマージン
                    let xOffset = geometry.size.width * 0.05
                    let yOffset = geometry.size.height * 0.05

                    for i in dataPoints.indices {
                        let dataPoint = dataPoints[i]
                        
                        // X座標の計算 (データポイントの数に基づいて均等に配置)
                        let xPosition: CGFloat
                        if dataPoints.count == 1 {
                            xPosition = drawingWidth / 2 // データが1つなら中央に
                        } else {
                            xPosition = CGFloat(i) * (drawingWidth / CGFloat(dataPoints.count - 1))
                        }
                        
                        // Y座標の計算 (Y軸は反転し、スプレッドに基づいてスケーリング)
                        let yPosition = drawingHeight * (1 - CGFloat((dataPoint.value - minY) / ySpread))

                        let actualX = xPosition + xOffset
                        let actualY = yPosition + yOffset

                        if i == 0 {
                            path.move(to: CGPoint(x: actualX, y: actualY))
                        } else {
                            path.addLine(to: CGPoint(x: actualX, y: actualY))
                        }
                        // データポイントに円を描画 (オプション)
                        // path.addEllipse(in: CGRect(x: actualX - 2, y: actualY - 2, width: 4, height: 4))
                    }
                }
                .stroke(strokeColor, lineWidth: 2)
            }
        }
    }
}
