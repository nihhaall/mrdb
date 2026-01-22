import 'package:amicons/amicons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:lottie/lottie.dart';
import 'package:mrdb/home/bottom_nav.dart';
import 'package:mrdb/home/navs/first_page/home_page.dart';
import 'package:mrdb/home/navs/first_page/preview_page.dart';
import 'package:mrdb/constens/keys.dart';
import 'package:mrdb/provider/client.dart';
import 'package:provider/provider.dart';
import 'package:shimmer/shimmer.dart';

import '../../main.dart';

class Favorite extends StatefulWidget {
  const Favorite({super.key});

  @override
  State<Favorite> createState() => _FavoriteState();
}
class _FavoriteState extends State<Favorite> {
  List favorites=[];
  String clientId='';
  List isDeleting=[];
  List searched=[];
  bool isClearing=false;
  bool notFound=false;
  bool load=false;
  TextEditingController favoritesSearch=TextEditingController();

  // void searchGet({required String query}) {
  //   favorites.;
  // }
  Future<void> getLiked({bool isCleared=false}) async {
    if(!isCleared)setState(() =>load=true);
    clientId = Provider.of<ClientProvider>(context, listen: false).clientId!;
    var client = FirebaseFirestore.instance.collection(AppConstants.phone).doc(clientId);
    var liks = await client.collection('liked').orderBy('timeStamp',descending: true).get();
    setState(() {
      favorites= liks.docs;
      load=false;
    });
  }
  Future<void> removeFav({required String id, required String title}) async {
    setState(() {
      isDeleting.add(id);
    });

    int attempt = 0;
    while (attempt < 3) {
      try {
        await FirebaseFirestore.instance
            .collection(AppConstants.phone)
            .doc(clientId)
            .collection('liked')
            .doc(id)
            .delete();


        setState(() {
          favorites.removeWhere((e) => e['id'].toString() == id);
          searched.removeWhere((e) => e['id'].toString() == id);
          isDeleting.remove(id);
        });

        if (mounted) {
          _showRemovalSnackBar(title, id);
        }
        return;
      } catch (e) {
        attempt++;
        if (attempt < 3) {
          await Future.delayed(Duration(seconds: 2));
        } else {
          if (mounted) {
            showScaffoldMsg(context, txt: 'Failed to remove. Please try again.');
          }
          setState(() {
            isDeleting.remove(id);
          });
        }
      }
    }
  }

  void _showRemovalSnackBar(String title, String id) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.grey[900],
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.all(wt * 0.05),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(wt * 0.03),
        ),
        content: Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green, size: wt * 0.05),
            SizedBox(width: wt * 0.03),
            Expanded(
              child: Text(
                '"$title" removed from favorites',
                style: TextStyle(color: Colors.white),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'UNDO',
          textColor: Colors.amber,
          onPressed: () async {

          },
        ),
        duration: Duration(seconds: 3),
      ),
    );
  }
  @override
  void initState() {
    getLiked();
    super.initState();
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          Container(
            padding: EdgeInsets.symmetric(horizontal: wt * 0.05, vertical: ht * 0.02),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'My Favorites',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: wt * 0.08,
                        letterSpacing: -0.5,
                      ),
                    ),
                    SizedBox(height: ht * 0.005),
                    Text(
                      'Your saved movies collection',
                      style: TextStyle(
                        color: Colors.grey[500],
                        fontSize: wt * 0.035,
                      ),
                    ),
                  ],
                ),
                Container(
                  width: wt * 0.15,
                  height: wt * 0.15,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.amber[700]!, Colors.amber[900]!],
                    ),
                    borderRadius: BorderRadius.circular(wt * 0.04),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.amber.withOpacity(0.3),
                        blurRadius: 15,
                        offset: Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Center(
                    child: load
                        ? LoadingAnimationWidget.staggeredDotsWave(
                      color: Colors.white,
                      size: wt * 0.05,
                    )
                        : Text(
                      favorites.length.toString(),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: wt * 0.05,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: wt * 0.05),
            child: Row(
              children: [
                Expanded(
                  flex: 7,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.grey[900],
                      borderRadius: BorderRadius.circular(wt * 0.04),
                      border: Border.all(
                        color: Colors.grey[800]!,
                        width: 1,
                      ),
                    ),
                    child: TextFormField(
                      enabled: favorites.isEmpty?false:true,
                      textInputAction: TextInputAction.search,
                      onChanged: (value) {
                        setState(() {
                          searched.clear();
                        });
                        for (var fav in favorites) {
                          if (fav['title'].toLowerCase().contains(value.toLowerCase().trim())) {
                            setState(() {
                              searched.add(fav);
                            });
                          }
                          setState(() {
                            if(value.isNotEmpty&&searched.isEmpty){
                              notFound=true;
                            }else{
                              notFound=false;
                            }
                          });
                        }
                        setState(() {
                          if (value.isNotEmpty && searched.isEmpty) {
                            notFound = true;
                          } else {
                            notFound = false;
                          }
                        });
                      },
                      textCapitalization: TextCapitalization.words,
                      controller: favoritesSearch,
                      cursorColor: Colors.amber,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                      decoration: InputDecoration(
                        fillColor: Colors.transparent,
                        filled: true,
                        hintText: 'Search favorites...',
                        hintStyle: TextStyle(color: Colors.grey[600]),
                        prefixIcon: Icon(Icons.search, color: Colors.grey[600]),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(wt * 0.04),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(wt * 0.04),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(wt * 0.04),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: wt * 0.03),
                Expanded(
                  flex: 3,
                  child: AnimatedContainer(
                    duration: Duration(milliseconds: 200),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: isClearing
                            ? [Colors.red[700]!, Colors.red[900]!]
                            : [Colors.red[600]!, Colors.red[800]!],
                      ),
                      borderRadius: BorderRadius.circular(wt * 0.04),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.red.withOpacity(0.3),
                          blurRadius: 10,
                          offset: Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: favorites.isEmpty
                            ? null
                            : () async {
                          setState(() {
                            isClearing = true;
                          });
                          for (var fav in favorites) {
                            await FirebaseFirestore.instance
                                .collection(AppConstants.phone)
                                .doc(clientId)
                                .collection('liked')
                                .doc(fav['id'].toString())
                                .delete();
                          }
                          await getLiked(isCleared: true);
                          setState(() {
                            isClearing = false;
                          });
                        },
                        borderRadius: BorderRadius.circular(wt * 0.04),
                        child: SizedBox(
                          height: ht * 0.055,
                          child: Center(
                            child: isClearing
                                ? LoadingAnimationWidget.horizontalRotatingDots(
                              color: Colors.white,
                              size: wt * 0.08,
                            )
                                : Text(
                              'Clear All',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                                fontSize: wt * 0.035,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          load?
          Expanded(
            child: Shimmer(
              direction: ShimmerDirection.ltr,
              period: Duration(milliseconds: 1000),
              gradient: LinearGradient(
                colors: [
                  Colors.grey.shade800,
                  Colors.grey.shade600,
                  Colors.grey.shade800,
                ],
                stops: [0.0, 0.5, 1.0],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
              child: Padding(
                padding: EdgeInsets.all(wt * 0.05),
                child: Expanded(
                  child: ListView.separated(
                    physics: NeverScrollableScrollPhysics(),
                    separatorBuilder: (context, index) => SizedBox(height: ht * 0.03),
                    itemCount: 3,
                    itemBuilder: (context, index) {
                      return Container(
                        width: wt * 1,
                        height: ht * 0.2,
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(wt * 0.04),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          )
              :
          favorites.isNotEmpty?
              notFound?
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        LottieBuilder.asset(
                          'assets/lottie/not_found.json',
                          width: wt * 0.5,
                          height: ht * 0.25,
                        ),
                        SizedBox(height: ht * 0.02),
                        Text(
                          'No results found',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: wt * 0.05,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: ht * 0.01),
                        Text(
                          'Try searching with different keywords',
                          style: TextStyle(
                            color: Colors.grey[500],
                            fontSize: wt * 0.035,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
                  :
              Expanded(
            child: Padding(
              padding: EdgeInsets.all(wt*0.05),
              child: ListView.separated(
                separatorBuilder: (context, index) => SizedBox(height: ht*0.03,),
                physics: BouncingScrollPhysics(),
                itemCount: searched.isNotEmpty?searched.length:favorites.length,
                itemBuilder: (context, index) {
                  var currentData=searched.isNotEmpty?searched:favorites;
                  return Container(
                    width: wt * 1,
                    height: ht * 0.22,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade800,
                      borderRadius: BorderRadius.circular(wt * 0.04),
                    ),
                    child: Row(
                      children: [
                        Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.only(
                                topLeft: Radius.circular(wt * 0.04),
                                bottomLeft: Radius.circular(wt * 0.04),
                              ),
                              child: SizedBox(
                                width: wt * 0.3,
                                height: ht * 0.22,
                                child: CachedNetworkImage(
                                  errorWidget: (context, url, error) => Icon(Amicons.iconly_image_2_fill,size: wt*0.2,color: Colors.white30),
                                  imageUrl: currentData[index]['img']??'',
                                  fit: BoxFit.cover,
                                  placeholder: (context, url) => LoadingAnimationWidget.fourRotatingDots(color: Colors.green, size: wt*0.08),
                                ),
                              ),
                            ),
                            Align(
                              alignment: AlignmentGeometry.topLeft,
                              child: Container(
                                  width: wt*0.15,
                                  height: ht*0.05,
                                  decoration: BoxDecoration(
                                    color: isDeleting.contains(currentData[index]['id'].toString())?Colors.black.withOpacity(0.7):Colors.red.shade900.withOpacity(0.8),
                                    borderRadius: BorderRadius.only(
                                      topLeft: Radius.circular(wt*0.04),
                                      bottomRight: Radius.circular(wt*0.04),
                                    ),
                                  ),
                                  child: isDeleting.contains(currentData[index]['id'].toString())?LoadingAnimationWidget.fallingDot(color: Colors.grey, size: wt*0.08):IconButton(
                                      onPressed: () {
                                        removeFav(id: currentData[index]['id'].toString(),title: currentData[index]['title']);
                                      },
                                      icon: Icon(Amicons.iconly_delete,color: Colors.black,size: wt*0.07,))
                              ),
                            )
                          ],
                        ),
                        Expanded(
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: wt * 0.03,
                              vertical: wt*0.04,
                            ),
                            color: Colors.transparent,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  flex: 4,
                                  child: Text(
                                    currentData[index]['title'],
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: wt * 0.05,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  flex: 2,
                                  child: Row(
                                    children: [
                                      Expanded(
                                        flex: 3,
                                        child: Container(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: wt * 0.02,
                                            vertical: wt * 0.01,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.yellow.withOpacity(0.1),
                                            borderRadius: BorderRadius.circular(wt * 0.02),
                                            border: Border.all(
                                              color: Colors.yellow.withOpacity(0.3),
                                              width: 2,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                                            children: [
                                              Icon(
                                                Amicons.vuesax_star_1,
                                                color: Colors.yellow,
                                                size: wt * 0.045,
                                              ),
                                              Text(
                                                (currentData[index]['rating']/2).toStringAsFixed(1).toString(),
                                                style: TextStyle(
                                                  color: Colors.yellow,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: wt * 0.035,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      SizedBox(width: wt * 0.01),
                                      Flexible(
                                        flex: 4,
                                        child: Container(
                                          padding: EdgeInsets.symmetric(horizontal: wt * 0.02, vertical: wt * 0.01),
                                          decoration: BoxDecoration(
                                            color: Colors.yellow.withOpacity(0.1),
                                            border: Border.all(
                                              color: Colors.yellow.withOpacity(0.3),
                                              width: 2,
                                            ),
                                            borderRadius: BorderRadius.circular(wt * 0.1),
                                          ),
                                          child: Center(
                                            child: Text(
                                              currentData[index]['year'],
                                              style: TextStyle(
                                                color: Colors.white54,
                                                fontWeight: FontWeight.bold,
                                                fontSize: wt * 0.034,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Spacer(),
                                Expanded(
                                  flex: 2,
                                  child: InkWell(
                                    onTap: () {
                                      Navigator.push(context, MaterialPageRoute(builder: (context) =>  MoviePreview(movieId: currentData[index]['id'],),));
                                    },
                                    child: Container(
                                      decoration: BoxDecoration(
                                          color: Colors.yellow.withOpacity(0.1),
                                          border: Border.all(
                                              color: Colors.yellow.withOpacity(0.3),
                                              width: 2
                                          ),
                                          borderRadius: BorderRadius.circular(wt*0.02)
                                      ),
                                      child: Center(
                                        child: Text('Details',style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: wt*0.045
                                        ),),
                                      ),
                                    ),
                                  ),
                                )
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          )
              :
          Container(
            alignment: Alignment.center,
            height: ht*0.5,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                LottieBuilder.asset(
                  'assets/lottie/not_found.json',
                  width: wt * 0.6,
                  height: ht * 0.3,
                ),
                Text(
                  'No favorites yet',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: wt * 0.06,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'Start adding movies to your collection',
                  style: TextStyle(
                    color: Colors.grey[500],
                    fontSize: wt * 0.04,
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.amber[700]!, Colors.amber[900]!],
                    ),
                    borderRadius: BorderRadius.circular(wt * 0.04),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () {
                        setState(() {
                          currentIndex=0;
                        });
                        Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => MainScreen()));
                      },
                      borderRadius: BorderRadius.circular(wt * 0.04),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: wt * 0.08,
                          vertical: ht * 0.02,
                        ),
                        child: Text(
                          'Browse Movies',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: wt * 0.045,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          )
        ],
      ),
    );
  }
}
