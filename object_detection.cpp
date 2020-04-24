#include <fstream>
#include <sstream>
#include <iostream>
#include <chrono>
#include <sched.h>
#include <cstdlib>
#include <cmath>

#include <opencv2/dnn.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/highgui.hpp>

#include "common.hpp"

#define A53_START 0
#define A73_START 2
#define A53_MAX 2
#define A73_MAX 4
std::string keys =
    "{ help  h     | | Print help message. }"
    "{ @alias      | | An alias name of model to extract preprocessing parameters from models.yml file. }"
    "{ zoo         | models.yml | An optional path to file with preprocessing parameters }"
    "{ device      |  0 | camera device number. }"
    "{ input i     | | Path to input image or video file. Skip this argument to capture frames from a camera. }"
    "{ framework f | | Optional name of an origin framework of the model. Detect it automatically if it does not set. }"
    "{ classes     | | Optional path to a text file with names of classes to label detected objects. }"
    "{ thr         | .5 | Confidence threshold. }"
    "{ nms         | .4 | Non-maximum suppression threshold. }"
    "{ backend     |  0 | Choose one of computation backends: "
                         "0: automatically (by default), "
                         "1: Halide language (http://halide-lang.org/), "
                         "2: Intel's Deep Learning Inference Engine (https://software.intel.com/openvino-toolkit), "
                         "3: OpenCV implementation }"
    "{ target      | 0 | Choose one of target computation devices: "
                         "0: CPU target (by default), "
                         "1: OpenCL, "
                         "2: OpenCL fp16 (half-float precision), "
                         "3: VPU }"
    "{ cluster    | 0 | Choose CPU cluster to use for computations: "
                         "0: Don't target specific cluster (by default), "
                         "1: A53 cluster, "
                         "2: A73 cluster }"
    "{ ncores     | 0 | Choose number of cores in clusters to use for computations: "
                         "0: Use all available cores (by default), "
                         "1 - n: Dependent on number of cores available }"
    "{ nframes    | 0 | Choose number of frames to count before terminating test: "
                         "0: No limit, user-timed termination (by default), "
                         "n: Terminate program after n number of frames processed }"
    "{ output     | | Postfix output file label. }"
    "{ freq       | 1704000 | Set CPU frequency. }"
    "{ grain      | 5 | Granularity of FPS calculations. }"
    "{ sframe     | 500 | Frames before switching CPU cluster. }"
    "{ test       | 0 | Choose test type: "
                         "0: No testing (by default), "
                         "1: Test FPS against frequency, "
                         "2: Test FPS against core migration. }";


using namespace cv;
using namespace dnn;

float confThreshold, nmsThreshold;
std::vector<std::string> classes;

void postprocess(Mat& frame, const std::vector<Mat>& out, Net& net);

void drawPred(int classId, float conf, int left, int top, int right, int bottom, Mat& frame);

void callback(int pos, void* userdata);

std::vector<String> getOutputsNames(const Net& net);

int main(int argc, char** argv)
{
    CommandLineParser parser(argc, argv, keys);

    const std::string modelName = parser.get<String>("@alias");
    const std::string zooFile = parser.get<String>("zoo");

    keys += genPreprocArguments(modelName, zooFile);

    parser = CommandLineParser(argc, argv, keys);
    parser.about("Use this script to run object detection deep learning networks using OpenCV.");
    if (argc == 1 || parser.has("help"))
    {
        parser.printMessage();
        return 0;
    }

    confThreshold = parser.get<float>("thr");
    nmsThreshold = parser.get<float>("nms");
    float scale = parser.get<float>("scale");
    Scalar mean = parser.get<Scalar>("mean");
    bool swapRB = parser.get<bool>("rgb");
    int inpWidth = parser.get<int>("width");
    int inpHeight = parser.get<int>("height");
    // additional flags for testing
    int cluster = parser.get<int>("cluster");
    int ncores = parser.get<int>("ncores");
    double nframes = parser.get<double>("nframes");
    int freq = parser.get<int>("freq");
    double grain = parser.get<double>("grain");
    double sframe = parser.get<double>("sframe");
    int test = parser.get<int>("test");
    CV_Assert(parser.has("model"));
    std::string modelPath = findFile(parser.get<String>("model"));
    std::string configPath = findFile(parser.get<String>("config"));

    // Open file with classes names.
    if (parser.has("classes"))
    {
        std::string file = parser.get<String>("classes");
        std::ifstream ifs(file.c_str());
        if (!ifs.is_open())
            CV_Error(Error::StsError, "File " + file + " not found");
        std::string line;
        while (std::getline(ifs, line))
        {
            classes.push_back(line);
        }
    }

    // Load a model.
    Net net = readNet(modelPath, configPath, parser.get<String>("framework"));
    net.setPreferableBackend(parser.get<int>("backend"));
    net.setPreferableTarget(parser.get<int>("target"));
    std::vector<String> outNames = net.getUnconnectedOutLayersNames();

    // Create a window
    static const std::string kWinName = "Deep learning object detection in OpenCV";
    namedWindow(kWinName, WINDOW_NORMAL);
    int initialConf = (int)(confThreshold * 100);
    createTrackbar("Confidence threshold, %", kWinName, &initialConf, 99, callback);

    // Open a video file or an image file or a camera stream.
    VideoCapture cap;
    if (parser.has("input"))
        cap.open(parser.get<String>("input"));
    else
        cap.open(parser.get<int>("device"));

    // Set which CPUs to run on (A53: 0-1, A73: 2-5)
    // Initialise CPU masks
    cpu_set_t a53_set;
    cpu_set_t a73_set;
    CPU_ZERO(&a53_set);
    CPU_ZERO(&a73_set);
    cpu_set_t set;
    CPU_ZERO(&set);
      std::string pathToFreq = "/sys/devices/system/cpu/cpufreq/";
      if (test == 1) {
	switch (cluster) {
	case 1:
	  if (ncores == 0 || ncores > A53_MAX) ncores = A53_MAX;
	  for (int i = A53_START; i < A53_START + ncores; i++) {
	    CPU_SET(i, &set);
	  }
	  pathToFreq += "policy0";
	  break;
	case 2:
	  if (ncores == 0 || ncores > A73_MAX) ncores = A73_MAX;
	  for (int i = A73_START; i < A73_START + ncores; i++) {
	    CPU_SET(i, &set);
	  }
	  pathToFreq += "policy2";
	  break;
	default:
	  break;
	}
	sched_setaffinity(0, sizeof(cpu_set_t), &set);
	// Set frequency
	std::string freqCommand = "sudo bash -c \'echo " + std::to_string(freq) + " > " + pathToFreq + "/scaling_setspeed\'";
	std::cout << freqCommand << std::endl;
	system(freqCommand.c_str());
      } else if (test == 2) {
	for (int i = A53_START; i < A53_START + A53_MAX; i++) CPU_SET(i, &a53_set);
	for (int i = A73_START; i < A73_START + A73_MAX; i++) CPU_SET(i, &a73_set);
	switch (cluster) {
	case 1:
	  sched_setaffinity(0, sizeof(cpu_set_t), &a53_set);
	  break;
	case 2:
	  sched_setaffinity(0, sizeof(cpu_set_t), &a73_set);
	  break;
	default:
	  break;
	}
      }
    // Data logging
    std::ofstream framesCount;
    std::string fileName = "data/log"; // subdirectory + prefix
    if (!parser.get<String>("output").empty()) {
      std::cout << "postfix: " << parser.get<String>("output") << std::endl;
      fileName = fileName + "_" + parser.get<String>("output") + ".csv";
    } else {
      std::cout << "No postfix entered" << std::endl;
      fileName = fileName + ".txt";
    }
    framesCount.open(fileName.c_str(), std::ofstream::app);
    double fCount = 0;
    auto start = std::chrono::steady_clock::now();
    auto samp_start = std::chrono::steady_clock::now();
    // Process frames.
    Mat frame, blob;    
    while (waitKey(1) < 0)
    {
        cap >> frame;
        if (frame.empty())
        {
            waitKey();
            break;
        }

        // Create a 4D blob from a frame.
        Size inpSize(inpWidth > 0 ? inpWidth : frame.cols,
                     inpHeight > 0 ? inpHeight : frame.rows);
        blobFromImage(frame, blob, scale, inpSize, mean, swapRB, false);

        // Run a model.
        net.setInput(blob);
        if (net.getLayer(0)->outputNameToIndex("im_info") != -1)  // Faster-RCNN or R-FCN
        {
            resize(frame, frame, inpSize);
            Mat imInfo = (Mat_<float>(1, 3) << inpSize.height, inpSize.width, 1.6f);
            net.setInput(imInfo, "im_info");
        }
        std::vector<Mat> outs;
        net.forward(outs, outNames);

        postprocess(frame, outs, net);

	fCount++;
	
        // Put efficiency information.
        std::vector<double> layersTimes;
        double freq = getTickFrequency() / 1000;
        double t = net.getPerfProfile(layersTimes) / freq;
        std::string label = format("Inference time: %.2f ms", t);
        putText(frame, label, Point(0, 15), FONT_HERSHEY_SIMPLEX, 0.5, Scalar(0, 255, 0));

        imshow(kWinName, frame);
	if (test == 2) {
	  // log FPS every grain frames and switch cluster after sframe frames
	  if (fmod(fCount, grain) == 0) {
	    auto samp_end = std::chrono::steady_clock::now();
	    std::chrono::duration<double> samp_duration = samp_end - samp_start;
	    std::chrono::duration<double> cumulative_duration = samp_end - start;
	    // initial cluster, total frame count, current FPS, average FPS
	    framesCount << fCount << "," << grain/samp_duration.count() << "," << fCount/cumulative_duration.count() << "\n";
	    samp_start = std::chrono::steady_clock::now();
	  }
	  if (sframe != 0 && fCount == sframe) {
	    cpu_set_t test_set;
	    CPU_ZERO(&test_set);
	    switch(cluster) {
	    case 1:
	      std::cout << "Changing CPUs (A53 to A73)..." << std::endl;
	      std::cout << "Old CPU count:" << CPU_COUNT(&a53_set) << std::endl;
	      sched_setaffinity(0, sizeof(cpu_set_t), &a73_set);
	      sched_getaffinity(0, sizeof(cpu_set_t), &test_set);
	      std::cout << "New CPU count: " << CPU_COUNT(&test_set) << std::endl;
	      std::cout << "Is equal? " << CPU_EQUAL(&a73_set, &test_set) << std::endl;
	      break;
	    case 2:
	      std::cout << "Changing CPUs (A73 to A53)..." << std::endl;
	      std::cout << "Old CPU count:" << CPU_COUNT(&a73_set) << std::endl;
	      sched_setaffinity(0, sizeof(cpu_set_t), &a53_set);
	      sched_getaffinity(0, sizeof(cpu_set_t), &test_set);
	      std::cout << "New CPU count: " << CPU_COUNT(&test_set) << std::endl;
	      std::cout << "Is equal? " << CPU_EQUAL(&a53_set, &test_set) << std::endl;
	      break;
	    default:
	      break;
	    }
	  }
	}
	if (nframes != 0 && fCount >= nframes) {
	  std::cout << "Frame limit reached --- exiting program" << std::endl;
	  break;
	}
    }

    if (test == 1) {
      auto end = std::chrono::steady_clock::now();
      std::chrono::duration<double> elapsed_seconds = end - start;
      // framesCount << "Frames processed, time elapsed (s): " << fCount << ", " << elapsed_seconds.count() << "\n";
      // framesCount << "Average FPS:" << fCount/elapsed_seconds.count() << "\n";
      framesCount << CPU_COUNT(&set) << "," << fCount/elapsed_seconds.count() << "," << freq << "\n";
    }
    framesCount.close();

    return 0;
}

void postprocess(Mat& frame, const std::vector<Mat>& outs, Net& net)
{
    static std::vector<int> outLayers = net.getUnconnectedOutLayers();
    static std::string outLayerType = net.getLayer(outLayers[0])->type;

    std::vector<int> classIds;
    std::vector<float> confidences;
    std::vector<Rect> boxes;
    if (net.getLayer(0)->outputNameToIndex("im_info") != -1)  // Faster-RCNN or R-FCN
    {
        // Network produces output blob with a shape 1x1xNx7 where N is a number of
        // detections and an every detection is a vector of values
        // [batchId, classId, confidence, left, top, right, bottom]
        CV_Assert(outs.size() == 1);
        float* data = (float*)outs[0].data;
        for (size_t i = 0; i < outs[0].total(); i += 7)
        {
            float confidence = data[i + 2];
            if (confidence > confThreshold)
            {
                int left = (int)data[i + 3];
                int top = (int)data[i + 4];
                int right = (int)data[i + 5];
                int bottom = (int)data[i + 6];
                int width = right - left + 1;
                int height = bottom - top + 1;
                classIds.push_back((int)(data[i + 1]) - 1);  // Skip 0th background class id.
                boxes.push_back(Rect(left, top, width, height));
                confidences.push_back(confidence);
            }
        }
    }
    else if (outLayerType == "DetectionOutput")
    {
        // Network produces output blob with a shape 1x1xNx7 where N is a number of
        // detections and an every detection is a vector of values
        // [batchId, classId, confidence, left, top, right, bottom]
        CV_Assert(outs.size() == 1);
        float* data = (float*)outs[0].data;
        for (size_t i = 0; i < outs[0].total(); i += 7)
        {
            float confidence = data[i + 2];
            if (confidence > confThreshold)
            {
                int left = (int)(data[i + 3] * frame.cols);
                int top = (int)(data[i + 4] * frame.rows);
                int right = (int)(data[i + 5] * frame.cols);
                int bottom = (int)(data[i + 6] * frame.rows);
                int width = right - left + 1;
                int height = bottom - top + 1;
                classIds.push_back((int)(data[i + 1]) - 1);  // Skip 0th background class id.
                boxes.push_back(Rect(left, top, width, height));
                confidences.push_back(confidence);
            }
        }
    }
    else if (outLayerType == "Region")
    {
        for (size_t i = 0; i < outs.size(); ++i)
        {
            // Network produces output blob with a shape NxC where N is a number of
            // detected objects and C is a number of classes + 4 where the first 4
            // numbers are [center_x, center_y, width, height]
            float* data = (float*)outs[i].data;
            for (int j = 0; j < outs[i].rows; ++j, data += outs[i].cols)
            {
                Mat scores = outs[i].row(j).colRange(5, outs[i].cols);
                Point classIdPoint;
                double confidence;
                minMaxLoc(scores, 0, &confidence, 0, &classIdPoint);
                if (confidence > confThreshold)
                {
                    int centerX = (int)(data[0] * frame.cols);
                    int centerY = (int)(data[1] * frame.rows);
                    int width = (int)(data[2] * frame.cols);
                    int height = (int)(data[3] * frame.rows);
                    int left = centerX - width / 2;
                    int top = centerY - height / 2;

                    classIds.push_back(classIdPoint.x);
                    confidences.push_back((float)confidence);
                    boxes.push_back(Rect(left, top, width, height));
                }
            }
        }
    }
    else
        CV_Error(Error::StsNotImplemented, "Unknown output layer type: " + outLayerType);

    std::vector<int> indices;
    NMSBoxes(boxes, confidences, confThreshold, nmsThreshold, indices);
    for (size_t i = 0; i < indices.size(); ++i)
    {
        int idx = indices[i];
        Rect box = boxes[idx];
        drawPred(classIds[idx], confidences[idx], box.x, box.y,
                 box.x + box.width, box.y + box.height, frame);
    }
}

void drawPred(int classId, float conf, int left, int top, int right, int bottom, Mat& frame)
{
    rectangle(frame, Point(left, top), Point(right, bottom), Scalar(0, 255, 0));

    std::string label = format("%.2f", conf);
    if (!classes.empty())
    {
        CV_Assert(classId < (int)classes.size());
        label = classes[classId] + ": " + label;
    }

    int baseLine;
    Size labelSize = getTextSize(label, FONT_HERSHEY_SIMPLEX, 0.5, 1, &baseLine);

    top = max(top, labelSize.height);
    rectangle(frame, Point(left, top - labelSize.height),
              Point(left + labelSize.width, top + baseLine), Scalar::all(255), FILLED);
    putText(frame, label, Point(left, top), FONT_HERSHEY_SIMPLEX, 0.5, Scalar());
}

void callback(int pos, void*)
{
    confThreshold = pos * 0.01f;
}
