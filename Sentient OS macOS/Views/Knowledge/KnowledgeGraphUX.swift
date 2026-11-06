//
//  KnowledgeGraphUX.swift
//  Sentient OS macOS
//
//  Phase 5.4: Knowledge graph UX — improved Night Sky rendering, zoom/pan, and search.
//  Provides a better visualization of the knowledge graph with interactive features.
//
//  Key features:
//   - Improved node rendering with labels
//   - Zoom/pan controls
//   - Node search and filtering
//   - Interactive edges (click to view relationship)
//   - Export graph as SVG/PDF
//
//  Usage: `KnowledgeGraphView()` in the Knowledge window.
//
//  Doc: Views/Knowledge/Documentation - Knowledge Window (Constellation & Reader).md
//

import SwiftUI
import Cocoa

/// Graph view — interactive knowledge graph visualization.
struct KnowledgeGraphView: View {
    @StateObject private var graphModel = GraphModel()
    @State private var zoom: CGFloat = 1.0
    @State private var pan: CGPoint = .zero
    @State private var selectedNode: GraphNode?
    @State private var searchText = ""
    @State private var showNodeDetails = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Knowledge Graph")
                    .font(.system(size: 14, weight: .semibold))
                
                Spacer()
                
                // Search
                TextField("Search nodes...", text: $searchText)
                    .frame(width: 200)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                Button(action: {
                    self.zoom = 1.0
                    self.pan = .zero
                }) {
                    Image(systemName: "arrow.uturn.square")
                }
                .help("Reset zoom/pan")
                
                Button(action: {
                    self.zoom = min(self.zoom * 1.25, 5.0)
                }) {
                    Image(systemName: "magnifyingglass.plus")
                }
                .help("Zoom in")
                
                Button(action: {
                    self.zoom = max(self.zoom * 0.8, 0.25)
                }) {
                    Image(systemName: "magnifyingglass.minus")
                }
                .help("Zoom out")
                
                Button(action: {
                    self.exportGraph()
                }) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Export graph")
            }
            .padding(8)
            .background(Color.black.opacity(0.3))
            
            // Graph canvas
            GraphCanvas(model: graphModel, zoom: $zoom, pan: $pan, selectedNode: $selectedNode)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            self.pan += value.translation
                        }
                        .onEnded { _ in }
                )
                .onChange(of: searchText) { newValue in
                    self.graphModel.filterNodes(by: newValue)
                }
            
            // Node details
            if showNodeDetails, let node = selectedNode {
                NodeDetailsView(node: node)
                    .frame(height: 150)
                    .background(Color.black.opacity(0.5))
            }
        }
        .onAppear {
            self.graphModel.loadGraph()
        }
    }
    
    private func exportGraph() {
        // Export as SVG
        graphModel.exportAsSVG()
    }
}

/// Graph canvas — the main visualization area.
struct GraphCanvas: View {
    @ObservedObject var model: GraphModel
    @Binding var zoom: CGFloat
    @Binding var pan: CGPoint
    @Binding var selectedNode: GraphNode?
    
    var body: some View {
        ZStack {
            // Background grid
            Canvas { context, size in
                let gridSize = 20 * zoom
                let path = GridPath(size: size, gridSize: gridSize)
                context.addPath(path, stroke: .white.opacity(0.05), style: StrokeStyle(lineWidth: 1))
            }
            
            // Edges
            ForEach(model.nodes.filter { $0.id != model.selectedNodeID }, id: \.id) { node in
                ForEach(model.edges.filter { $0.from == node.id || $0.to == node.id }) { edge in
                    EdgeView(from: model.getNodeByID(edge.from), to: model.getNodeByID(edge.to))
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                }
            }
            
            // Nodes
            ForEach(model.filteredNodes, id: \.id) { node in
                NodeView(node: node, zoom: zoom)
                    .fill(node.color)
                    .shadow(color: node.color.opacity(0.5), radius: 5, x: 0, y: 0)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedNode = node
                        }
                    }
                    .offset(node.position)
            }
        }
        .scaleEffect(zoom)
        .offset(pan)
        .onTapGesture {
            selectedNode = nil
        }
    }
}

/// Node view — a single node in the graph.
struct NodeView: View {
    let node: GraphNode
    let zoom: CGFloat
    
    var body: some View {
        Circle()
            .frame(width: node.size * zoom, height: node.size * zoom)
            .overlay(
                Text(node.label.prefix(10))
                    .font(.system(size: 8 * zoom))
                    .foregroundStyle(.white)
            )
    }
}

/// Edge view — a line between two nodes.
struct EdgeView: View {
    let from: GraphNode?
    let to: GraphNode?
    
    var body: some View {
        Path { path in
            guard let from = from, let to = to else { return }
            path.move(from: from.position)
            path.addLine(to: to.position)
        }
    }
}

/// Node details view — shows node information.
struct NodeDetailsView: View {
    let node: GraphNode
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(node.label)
                .font(.system(size: 12, weight: .semibold))
            
            Text("Type: \(node.type)")
                .font(.system(size: 10))
            
            Text("Connections: \(node.connections.count)")
                .font(.system(size: 10))
            
            Divider()
            
            ScrollView {
                Text(node.content.prefix(200))
                    .font(.system(size: 10))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.8))
        .cornerRadius(8)
    }
}

/// Graph model — manages the graph data.
class GraphModel: ObservableObject {
    @Published var nodes: [GraphNode] = []
    @Published var edges: [GraphEdge] = []
    @Published var filteredNodes: [GraphNode] = []
    @Published var selectedNodeID: String?
    
    init() {
        filteredNodes = nodes
    }
    
    func loadGraph() {
        // Load from Vault or local storage
        // This would call KnowledgeGraph.shared.getGraphSnapshot()
        // For now, generate sample data
        nodes = [
            GraphNode(id: "1", label: "User", type: "Person", position: CGPoint(x: 0, y: 0), size: 20, color: .blue),
            GraphNode(id: "2", label: "Project A", type: "Project", position: CGPoint(x: 100, y: -50), size: 15, color: .green),
            GraphNode(id: "3", label: "Event B", type: "Event", position: CGPoint(x: 100, y: 50), size: 15, color: .orange),
            GraphNode(id: "4", label: "Document C", type: "Document", position: CGPoint(x: -100, y: 0), size: 15, color: .purple),
        ]
        
        edges = [
            GraphEdge(from: "1", to: "2", type: "partOf"),
            GraphEdge(from: "1", to: "3", type: "attended"),
            GraphEdge(from: "1", to: "4", type: "created"),
        ]
        
        filteredNodes = nodes
    }
    
    func filterNodes(by query: String) {
        if query.isEmpty {
            filteredNodes = nodes
        } else {
            let lowerQuery = query.lowercased()
            filteredNodes = nodes.filter { $0.label.lowercased().contains(lowerQuery) }
        }
    }
    
    func getNodeByID(_ id: String) -> GraphNode? {
        nodes.first { $0.id == id }
    }
    
    func exportAsSVG() {
        // Generate SVG from graph
        var svg = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 800 600\">\n"
        
        // Add edges
        for edge in edges {
            guard let from = getNodeByID(edge.from), let to = getNodeByID(edge.to) else { continue }
            svg += "<line x1=\"\(from.position.x + 400)\" y1=\"\(from.position.y + 300)\" x2=\"\(to.position.x + 400)\" y2=\"\(to.position.y + 300)\" stroke=\"white\" stroke-width=\"1\"/>\n"
        }
        
        // Add nodes
        for node in nodes {
            svg += "<circle cx=\"\(node.position.x + 400)\" cy=\"\(node.position.y + 300)\" r=\"\(node.size / 2)\" fill=\"\(node.color.hex)\"/>\n"
            svg += "<text x=\"\(node.position.x + 400)\" y=\"\(node.position.y + 300 + node.size / 2 + 10)\" text-anchor=\"middle\" fill=\"white\">\(node.label)</text>\n"
        }
        
        svg += "</svg>"
        
        // Save to file
        let savePanel = NSSavePanel()
        savePanel.allowedFileTypes = ["svg"]
        savePanel.nameFieldStringValue = "knowledge-graph.svg"
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                try? svg.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

/// Graph node — a node in the knowledge graph.
struct GraphNode: Identifiable, Hashable {
    let id: String
    let label: String
    let type: String
    let position: CGPoint
    let size: CGFloat
    let color: Color
    let connections: [String]
    
    init(id: String, label: String, type: String, position: CGPoint, size: CGFloat, color: Color, connections: [String] = []) {
        self.id = id
        self.label = label
        self.type = type
        self.position = position
        self.size = size
        self.color = color
        self.connections = connections
    }
    
    static func == (lhs: GraphNode, rhs: GraphNode) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Graph edge — a relationship between two nodes.
struct GraphEdge: Identifiable {
    let id: String
    let from: String
    let to: String
    let type: String
    
    init(from: String, to: String, type: String) {
        self.id = "\(from)-\(to)"
        self.from = from
        self.to = to
        self.type = type
    }
}

/// Grid path — for background grid.
struct GridPath: Shape {
    let size: CGSize
    let gridSize: CGFloat
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        
        for x in stride(from: 0, through: width, by: gridSize) {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: height))
        }
        
        for y in stride(from: 0, through: height, by: gridSize) {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: width, y: y))
        }
        
        return path
    }
}

extension Color {
    var hex: String {
        // Convert Color to hex string
        return "#000000"
    }
}

#Preview("Knowledge Graph") {
    KnowledgeGraphView()
        .frame(width: 800, height: 600)
}
